defmodule RockstatFront.Rpc do
  @moduledoc """
  JSON-RPC 2.0 over Redis pub/sub, wire-compatible with rock-me-ts
  `RPCAgnostic` + `RPCAdapterRedis`:

  * outgoing messages are published to the channel named after the target
    service, `method` encoded as `"to:method:from"`;
  * we listen on our own channel(s) (`front_N`, `director`);
  * `request/4` waits for a response by id; multi-requests (enrichers)
    collect answers from a known set of services into a bag until timeout;
  * incoming requests are dispatched to locally registered methods.
  """

  use GenServer
  require Logger

  alias RockstatFront.{Config, Ids, Metrics}

  # дефолтный таймаут ожидания ответа, как в rock-me-ts (this.timeout = 200)
  @default_timeout 200

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Уведомление без ожидания ответа (сообщение без id)."
  def notify(target, method, params) do
    GenServer.cast(__MODULE__, {:notify, target, method, params})
  end

  @doc """
  Запрос-ответ. Возвращает `{:ok, result}` / `{:error, reason}`.

  `opts`:
    * `:timeout` — мс ожидания (по умолчанию 200);
    * `:services` — список сервисов для multi-запроса (энричеры): ответы
      собираются в bag %{сервис => результат}; по таймауту возвращается
      то, что успело прийти, без ошибки.
  """
  def request(target, method, params, opts \\ []) do
    services = opts[:services]

    # multi-запрос без адресатов не отправляем вовсе (как в TS)
    if services == [] do
      {:ok, nil}
    else
      timeout = opts[:timeout] || @default_timeout

      # ответ придёт позже через GenServer.reply (из dispatch_* или по
      # таймеру), поэтому таймаут самого call-а берём с запасом
      GenServer.call(
        __MODULE__,
        {:request, target, method, params, services || [], timeout},
        timeout + 1_000
      )
    end
  end

  @doc "Регистрация локального метода (вызываемого другими сервисами): fun(params) -> result."
  def register(method, fun), do: GenServer.call(__MODULE__, {:register, method, fun})

  # — GenServer —

  # Два соединения с Redis: обычное для PUBLISH и отдельное pub/sub
  # для подписки на свои каналы (front_N — личный, director — общий).
  @impl true
  def init(_opts) do
    rpc_cfg = Config.get("rpc")
    name = rpc_cfg["name"]
    channels = rpc_cfg["channels"] || [name]

    redis_url = Config.get(["redis", "dsn"], "redis://127.0.0.1:6379")

    {:ok, pub} = Redix.start_link(redis_url, name: :rpc_pub)
    {:ok, pubsub} = Redix.PubSub.start_link(redis_url)

    for chan <- channels do
      {:ok, _ref} = Redix.PubSub.subscribe(pubsub, chan, self())
    end

    {:ok,
     %{
       name: name,
       pub: pub,
       pubsub: pubsub,
       queue: %{},
       methods: %{}
     }}
  end

  @impl true
  def handle_call({:register, method, fun}, _from, state) do
    {:reply, :ok, put_in(state.methods[method], fun)}
  end

  # Исходящий запрос: публикуем и запоминаем ожидание в queue.
  # Ответ клиенту уйдёт через GenServer.reply, когда придёт response
  # с этим id (или сработает таймер).
  def handle_call({:request, target, method, params, services, timeout}, from, state) do
    id = Ids.round()
    multi = services != []

    publish(state, target, %{
      "jsonrpc" => "2.0",
      "from" => state.name,
      "to" => target,
      "id" => id,
      "method" => "#{target}:#{method}:#{state.name}",
      "params" => params
    })

    timer = Process.send_after(self(), {:rpc_timeout, id}, timeout)

    call = %{
      from: from,
      multi: multi,
      services: services,
      bag: %{},
      timer: timer,
      timing: Metrics.timenote("rpc.request")
    }

    {:noreply, put_in(state.queue[id], call)}
  end

  @impl true
  def handle_cast({:notify, target, method, params}, state) do
    publish(state, target, %{
      "jsonrpc" => "2.0",
      "from" => state.name,
      "to" => target,
      "method" => "#{target}:#{method}:#{state.name}",
      "params" => params
    })

    {:noreply, state}
  end

  # Входящее сообщение из Redis: принимаем только валидный JSON-RPC 2.0,
  # всё прочее молча игнорируем (в каналах может быть посторонний трафик)
  @impl true
  def handle_info({:redix_pubsub, _pid, _ref, :message, %{payload: payload}}, state) do
    case Jason.decode(payload) do
      {:ok, %{"jsonrpc" => "2.0"} = msg} -> {:noreply, dispatch(msg, state)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:redix_pubsub, _pid, _ref, event, _info}, state)
      when event in [:subscribed, :disconnected] do
    {:noreply, state}
  end

  # Таймаут ожидания: multi-запрос считается успешным с тем, что собрали
  # (часть энричеров могла не ответить), одиночный — ошибкой
  def handle_info({:rpc_timeout, id}, state) do
    case Map.pop(state.queue, id) do
      {nil, _} ->
        {:noreply, state}

      {call, queue} ->
        if call.multi do
          GenServer.reply(call.from, {:ok, call.bag})
        else
          Metrics.tick("rpc.timeout")
          GenServer.reply(call.from, {:error, :timeout})
        end

        {:noreply, %{state | queue: queue}}
    end
  end

  # Готовый ответ локального метода (выполнялся в Task-е) — публикуем
  # его в канал сервиса-инициатора
  def handle_info({:local_result, reply_to, response}, state) do
    publish(state, reply_to, response)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # — маршрутизация входящих сообщений —

  # Входящий запрос к нашему локальному методу. Поле method на проводе
  # кодируется как "to:method:from" (формат rock-me-ts) — распаковываем.
  defp dispatch(%{"method" => method} = msg, state) when is_binary(method) do
    {_to, method, from} =
      case String.split(method, ":") do
        [t, m, f] -> {t, m, f}
        _ -> {nil, method, msg["from"]}
      end

    case Map.fetch(state.methods, method) do
      {:ok, fun} ->
        run_local(fun, msg, from, state)

      :error ->
        Logger.debug("rpc: unhandled method #{method}")
        state
    end
  end

  # Входящий ответ на один из наших запросов (id есть в очереди ожидания)
  defp dispatch(%{"id" => id} = msg, state) when is_map_key(state.queue, id) do
    call = state.queue[id]

    cond do
      call.multi -> dispatch_multi(msg, id, call, state)
      true -> dispatch_single(msg, id, call, state)
    end
  end

  defp dispatch(msg, state) do
    Logger.debug("rpc: unhandled message #{inspect(Map.take(msg, ["id", "from", "to"]))}")
    state
  end

  # Одиночный запрос: отдаём результат ждущему процессу и чистим очередь
  defp dispatch_single(msg, id, call, state) do
    Process.cancel_timer(call.timer)
    call.timing.()

    reply =
      cond do
        Map.has_key?(msg, "result") -> {:ok, unwrap_result(msg["result"])}
        Map.has_key?(msg, "error") -> {:error, msg["error"]}
        true -> {:error, :bad_response}
      end

    GenServer.reply(call.from, reply)
    %{state | queue: Map.delete(state.queue, id)}
  end

  # Multi-запрос: каждый ответ вычёркивает сервис из списка ожидаемых
  # и кладёт результат в bag; когда ответили все — отдаём bag целиком.
  # Ответы от сервисов не из списка игнорируются.
  defp dispatch_multi(msg, id, call, state) do
    from_svc = msg["from"]

    if from_svc in call.services do
      services = List.delete(call.services, from_svc)

      bag =
        if Map.has_key?(msg, "result") do
          Map.put(call.bag, msg["service_group"] || from_svc, msg["result"])
        else
          Logger.warning("rpc: error response from #{from_svc}")
          call.bag
        end

      if services == [] do
        Process.cancel_timer(call.timer)
        call.timing.()
        GenServer.reply(call.from, {:ok, bag})
        %{state | queue: Map.delete(state.queue, id)}
      else
        put_in(state.queue[id], %{call | services: services, bag: bag})
      end
    else
      state
    end
  end

  # Совместимость с rock-me-ts: ответ вида BandResponse c type__ == data
  # разворачивается до внутреннего data (остальные типы — как есть)
  defp unwrap_result(%{"type__" => "data", "data" => data} = _result)
       when is_map(data),
       do: data

  defp unwrap_result(result), do: result

  # Выполнение локального метода (__iamalive, status, enrichers...).
  # Запускается в отдельном Task-е, чтобы не блокировать цикл RPC:
  # метод может сам делать RPC-запросы (как __iamalive -> status).
  # Ответ публикуется только если запрос был с id (иначе это notify).
  defp run_local(fun, msg, from, state) do
    me = self()
    name = state.name
    id = msg["id"]

    Task.start(fn ->
      result =
        try do
          fun.(msg["params"] || %{})
        rescue
          e ->
            Logger.error("rpc local handler error: #{Exception.message(e)}")
            {:error, Exception.message(e)}
        end

      if id != nil do
        response =
          case result do
            {:error, message} ->
              %{
                "jsonrpc" => "2.0",
                "id" => id,
                "from" => name,
                "to" => from,
                "error" => %{"code" => 0, "message" => inspect(message), "data" => %{}}
              }

            value ->
              %{
                "jsonrpc" => "2.0",
                "id" => id,
                "from" => name,
                "to" => from,
                "result" => unwrap_ok(value)
              }
          end

        send(me, {:local_result, from, response})
      end
    end)

    state
  end

  defp unwrap_ok({:ok, v}), do: v
  defp unwrap_ok(v), do: v

  defp publish(state, channel, msg) do
    case Jason.encode(msg) do
      {:ok, raw} ->
        case Redix.command(state.pub, ["PUBLISH", channel, raw]) do
          {:ok, _} -> :ok
          {:error, reason} -> Logger.error("rpc publish failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("rpc encode failed: #{inspect(reason)}")
    end
  end
end
