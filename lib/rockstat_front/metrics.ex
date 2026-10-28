defmodule RockstatFront.Metrics do
  @moduledoc "Minimal statsd UDP client: counters (`tick`) and timings (`timing`)."

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Инкремент счётчика (statsd counter)."
  def tick(name, value \\ 1), do: GenServer.cast(__MODULE__, {:send, "#{name}:#{value}|c"})

  @doc "Отправка замера длительности в мс (statsd timing)."
  def timing(name, ms), do: GenServer.cast(__MODULE__, {:send, "#{name}:#{ms}|ms"})

  @doc """
  Возвращает функцию-"секундомер" (аналог TS `timenote`): вызов отправляет
  timing с прошедшим временем и возвращает его.
  """
  def timenote(name) do
    started = System.monotonic_time(:millisecond)

    fn ->
      elapsed = System.monotonic_time(:millisecond) - started
      timing(name, elapsed)
      elapsed
    end
  end

  @impl true
  def init(_opts) do
    cfg = RockstatFront.Config.get(["metrics", "statsd"], %{}) || %{}
    host = String.to_charlist(cfg["host"] || "127.0.0.1")
    port = cfg["port"] || 8125
    prefix = cfg["prefix"] || "krn"
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
    {:ok, %{socket: socket, host: host, port: port, prefix: prefix}}
  end

  # Отправка — fire-and-forget UDP: ошибки игнорируются, недоступный
  # statsd не влияет на обработку запросов
  @impl true
  def handle_cast({:send, payload}, state) do
    _ = :gen_udp.send(state.socket, state.host, state.port, "#{state.prefix}.#{payload}")
    {:noreply, state}
  end
end
