defmodule RockstatFront.Dispatcher do
  @moduledoc """
  Message pipeline, port of src/Dispatcher.ts:

    transform -> enrich (merge results into data) -> handle -> notify listeners

  The GenServer owns the routing state and rebuilds it from remote service
  registrations (`__iamalive` -> `status` RPC, 15s expiry, 5s rebuild tick).
  The actual `dispatch/2` runs in the caller process against an ETS snapshot,
  so requests do not serialize through this process.
  """

  use GenServer
  require Logger

  alias RockstatFront.{
    BandResponse,
    Config,
    Handlers,
    Enrichers,
    Transformers,
    TreeBus,
    Ids,
    Rpc,
    Helpers
  }

  # ETS-таблица со снэпшотом роутинга (читается из процессов запросов)
  @table :front_routing
  # период полной пересборки роутинга из регистраций
  @rebuild_every 5_000
  # сколько живёт регистрация сервиса без нового __iamalive
  @reg_ttl 15_000
  # канал/метод широковещательной рассылки listener-сервисам (ClickHouse и пр.)
  @broadcast "broadcast"
  # общий канал/метод удалённых энричеров
  @enrich "enrich"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # — пайплайн (выполняется в процессе HTTP-запроса, не в GenServer-е!) —

  @doc """
  Прогоняет сообщение через все фазы и возвращает ответ клиенту.
  Порядок фаз как в Dispatcher.ts: transform -> enrich -> handle -> listeners.
  """
  @spec dispatch(String.t(), map()) :: BandResponse.t()
  def dispatch(key, msg) do
    routing = snapshot()

    # каждому сообщению — уникальный flake-id и серверное время
    msg =
      msg
      |> Map.put("id", Ids.flake())
      |> Map.put("time", System.system_time(:millisecond))

    # Фаза 1: трансформация. Самый специфичный трансформер по ключу
    # (например, PostHog-батч -> конверт + отдельные события);
    # по умолчанию — identity, submsgs пуст.
    {msg, submsgs} =
      case TreeBus.resolve(routing.transform, key) do
        {{:internal, mod}, _path} -> mod.handle(key, msg)
        _ -> {msg, []}
      end

    # распакованные из батча события получают собственные id
    submsgs = Enum.map(submsgs, &Map.put(&1, "id", Ids.flake()))

    # Фаза 2: обогащение. Запускаются ВСЕ подходящие энричеры:
    # внутренние (UserData из Redis) и шлюз удалённых (:remote_gateway
    # подписан на '*') — параллельно, как Promise.all в оригинале.
    # Результаты мержатся в msg["data"].
    enrichments =
      routing.enrich
      |> TreeBus.collect(key)
      |> Enum.map(fn
        {{:internal, mod}, _} ->
          fn -> safe(fn -> mod.handle(key, msg) end, %{}) end

        {:remote_gateway, _} ->
          fn -> remote_enrich(routing, key, msg) end
      end)
      |> run_concurrently()
      |> Enum.reject(&(&1 == %{} or is_nil(&1)))

    {msg, submsgs} =
      if enrichments != [] and is_map(msg["data"]) do
        merged = Enum.reduce(enrichments, msg["data"], &Map.merge(&2, &1))

        {Map.put(msg, "data", merged),
         Enum.map(submsgs, fn sub -> Enum.reduce(enrichments, sub, &Map.merge(&2, &1)) end)}
      else
        {msg, submsgs}
      end

    # Фаза 3: обработка. Один, самый специфичный обработчик:
    # внутренний модуль (pixel/redirect/track/...), удалённый сервис
    # через RPC-шлюз, либо дефолтный ответ {key, id, uid}.
    handled =
      case TreeBus.resolve(routing.handle, key) do
        {{:internal, mod}, _path} -> safe(fn -> mod.handle(key, msg) end, BandResponse.error([]))
        {:rpc_gateway, path} -> remote_handle(routing, path, key, msg)
        _ -> Handlers.default(key, msg)
      end

    # Фаза 4: слушатели. Fire-and-forget рассылка в канал broadcast
    # (конверт и каждое распакованное событие) — ответа не ждём,
    # клиента не задерживаем.
    Task.Supervisor.start_child(RockstatFront.TaskSup, fn ->
      Rpc.notify(@broadcast, @broadcast, msg)
      Enum.each(submsgs, &Rpc.notify(@broadcast, @broadcast, &1))
    end)

    handled
  end

  # Шлюз удалённых энричеров: по дереву remote_enrichers находим, какие
  # сервисы подписаны на этот ключ, отправляем им multi-запрос в общий канал
  # `enrich` с усечённым сообщением (только поля из requirements) и получаем
  # bag %{имя_сервиса => результат}, который целиком мержится в data.
  defp remote_enrich(routing, key, msg) do
    services = routing.remote_enrichers |> TreeBus.collect(key) |> Enum.map(&elem(&1, 0))

    if services == [] do
      %{}
    else
      small = Helpers.getvals(msg, routing.requirements)

      case Rpc.request(@enrich, @enrich, small, services: Enum.uniq(services)) do
        {:ok, bag} when is_map(bag) -> bag
        _ -> %{}
      end
    end
  end

  # Шлюз удалённых обработчиков: сообщение уходит RPC-запросом конкретному
  # сервису. Если тот вернул карту с type__ — это готовый BandResponse
  # (редирект, пиксель...), иначе результат заворачивается в data-ответ.
  # Таймаут/ошибка -> 500 с текстом.
  defp remote_handle(routing, path, key, msg) do
    case Map.get(routing.rpc_handlers, path) do
      nil ->
        Handlers.default(key, msg)

      {service, method, options} ->
        case Rpc.request(service, method, msg, timeout: options["timeout"] || 200) do
          {:ok, %{"type__" => _} = result} ->
            BandResponse.from_map(result)

          {:ok, result} ->
            BandResponse.data(data: result)

          {:error, reason} ->
            Logger.warning("remote handler #{service}.#{method} failed: #{inspect(reason)}")
            BandResponse.error(status: 500, message: error_message(reason))
        end
    end
  end

  defp error_message(:timeout), do: "Request timeout"
  defp error_message(%{"message" => m}), do: m
  defp error_message(other), do: inspect(other)

  # Параллельный запуск энричеров. Один энричер выполняется на месте
  # (без накладных расходов на процесс); несколько — в Task-ах с общим
  # потолком ожидания: не ответивший вовремя даёт %{} и убивается,
  # не задерживая ответ клиенту.
  @enrich_deadline 2_000

  defp run_concurrently([]), do: []
  defp run_concurrently([fun]), do: [fun.()]

  defp run_concurrently(funs) do
    funs
    |> Enum.map(&Task.Supervisor.async_nolink(RockstatFront.TaskSup, &1))
    |> Task.yield_many(timeout: @enrich_deadline, on_timeout: :kill_task)
    |> Enum.map(fn
      {_task, {:ok, value}} -> value
      {_task, _timeout_or_crash} -> %{}
    end)
  end

  # ошибка одной фазы не роняет запрос: логируем и продолжаем с fallback-ом
  defp safe(fun, fallback) do
    fun.()
  rescue
    e ->
      Logger.error("dispatcher stage error: #{Exception.message(e)}")
      fallback
  end

  # текущий снэпшот роутинга из ETS (дёшево, без обращения к GenServer-у)
  defp snapshot, do: :ets.lookup_element(@table, :snapshot, 2)

  # — GenServer: учёт регистраций удалённых сервисов и пересборка роутинга —

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])

    state = %{regs: %{}, reg_timers: %{}}
    rebuild(state.regs)

    Rpc.register("__iamalive", &iamalive/1)
    Rpc.register("enrichers", fn _ -> %{} end)

    :timer.send_interval(@rebuild_every, :rebuild)
    {:ok, state}
  end

  # Вызывается из Rpc-таска: сервис прислал __iamalive — запрашиваем у него
  # `status` и сохраняем его register (список handler/enricher-объявлений).
  defp iamalive(%{"name" => name}) when is_binary(name) do
    case Rpc.request(name, "status", %{}) do
      {:ok, %{"name" => svc_name, "register" => register}} when is_list(register) ->
        GenServer.cast(__MODULE__, {:service_status, svc_name, register})

      _ ->
        :ok
    end

    nil
  end

  defp iamalive(_), do: nil

  # Свежая регистрация сервиса: перезаводим таймер её жизни (TTL 15с —
  # сервис, переставший слать __iamalive, выпадает из роутинга)
  @impl true
  def handle_cast({:service_status, name, register}, state) do
    if timer = state.reg_timers[name], do: Process.cancel_timer(timer)
    timer = Process.send_after(self(), {:reg_expired, name}, @reg_ttl)

    regs = Map.put(state.regs, name, register)
    rebuild(regs)
    {:noreply, %{state | regs: regs, reg_timers: Map.put(state.reg_timers, name, timer)}}
  end

  @impl true
  def handle_info({:reg_expired, name}, state) do
    regs = Map.delete(state.regs, name)
    rebuild(regs)
    {:noreply, %{state | regs: regs, reg_timers: Map.delete(state.reg_timers, name)}}
  end

  def handle_info(:rebuild, state) do
    rebuild(state.regs)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Собирает полный снэпшот роутинга: статическая часть из конфига (bus:)
  # + динамическая из живых регистраций. Кладёт результат в ETS атомарно.
  defp rebuild(regs) do
    bus_cfg = Config.get("bus", %{}) || %{}

    transform =
      build_tree(bus_cfg["transformers"] || %{}, Transformers.by_name())

    # шлюз удалённых энричеров подписан на '*' — он сам решает по дереву
    # remote_enrichers, есть ли адресаты для конкретного ключа
    enrich =
      build_tree(bus_cfg["enrichers"] || %{}, Enrichers.by_name())
      |> TreeBus.subscribe("*", :remote_gateway)

    handle =
      build_tree(bus_cfg["handlers"] || %{}, Handlers.by_name())

    # Разбор регистраций: каждый сервис объявляет методы с ролью
    # handler (принимает события по ключу in.gen.<svc>[.<method>])
    # или enricher (подписан на ключи options.keys, хочет поля options.props)
    {rpc_handlers, handle, remote_enrichers, requirements} =
      Enum.reduce(regs, {%{}, handle, TreeBus.new(), []}, fn {service, register}, acc ->
        Enum.reduce(register, acc, fn item, {rh, ht, re, reqs} ->
          method = item["method"]
          options = item["options"] || %{}

          # сервис может публиковаться под псевдонимом (options.alias)
          route_service = options["alias"] || service

          # method '*' означает "все события сервиса" — сегмент опускается
          routing_key =
            ["in", "gen", route_service | List.wrap(if method != "*", do: method)]
            |> Enum.join(".")

          case item["role"] do
            "handler" ->
              {Map.put(rh, routing_key, {service, method, options}),
               TreeBus.subscribe(ht, routing_key, :rpc_gateway), re, reqs}

            "enricher" ->
              keys = options["keys"] || []
              re = Enum.reduce(keys, re, &TreeBus.subscribe(&2, &1, route_service))

              new_reqs =
                case options["props"] do
                  props when is_map(props) -> Enum.map(props, fn {k, v} -> [k, v] end)
                  _ -> []
                end

              {rh, ht, re, reqs ++ new_reqs}

            _ ->
              {rh, ht, re, reqs}
          end
        end)
      end)

    :ets.insert(
      @table,
      {:snapshot,
       %{
         transform: transform,
         enrich: enrich,
         handle: handle,
         rpc_handlers: rpc_handlers,
         remote_enrichers: remote_enrichers,
         requirements: requirements
       }}
    )
  end

  # Дерево из секции конфига: %{"ИмяМодуля" => ключ | [ключи]}.
  # repo — карта имён на внутренние модули (Handlers.by_name() и т.п.)
  defp build_tree(config, repo) do
    Enum.reduce(config, TreeBus.new(), fn {name, chans}, tree ->
      case Map.fetch(repo, name) do
        {:ok, mod} ->
          chans
          |> List.wrap()
          |> Enum.reduce(tree, &TreeBus.subscribe(&2, &1, {:internal, mod}))

        :error ->
          Logger.warning("unknown bus member in config: #{name}")
          tree
      end
    end)
  end
end
