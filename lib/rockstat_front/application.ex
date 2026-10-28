defmodule RockstatFront.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # конфиг и статика грузятся до старта детей — супервизируемые процессы
    # могут читать их из persistent_term сразу в init
    config = RockstatFront.Config.load!()
    RockstatFront.StaticData.load!()

    http = config["http"] || %{}
    port = to_int(http["port"], 8080)
    host = http["host"] || "0.0.0.0"

    Logger.info(
      "Starting #{config["name"]} v#{config["version"]} (#{RockstatFront.Config.env()})"
    )

    Logger.info("HTTP transport #{host}:#{port}")

    # Порядок детей важен: Rpc нужен Dispatcher-у (регистрирует методы
    # в init), :redix — энричеру UserData, TaskSup — broadcast-рассылке
    children = [
      # супервизор фоновых задач (broadcast, локальные RPC-методы)
      {Task.Supervisor, name: RockstatFront.TaskSup},
      RockstatFront.Metrics,
      RockstatFront.Ids,
      # общее Redis-соединение для команд (HGETALL/HMSET в UserData)
      {Redix,
       {RockstatFront.Config.get(["redis", "dsn"], "redis://127.0.0.1:6379"), [name: :redix]}},
      RockstatFront.Rpc,
      RockstatFront.Dispatcher,
      {
        Bandit,
        # keep idle keep-alive connections longer than nginx upstream
        # keepalive_timeout (60s default) to avoid 502 close races
        plug: RockstatFront.Http.Router,
        scheme: :http,
        ip: parse_ip(host),
        port: port,
        http_options: [],
        thousand_island_options: [read_timeout: 75_000]
      }
    ]

    opts = [strategy: :one_for_one, name: RockstatFront.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp parse_ip(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> ip
      _ -> {0, 0, 0, 0}
    end
  end

  defp to_int(v, default) do
    case v do
      nil -> default
      n when is_integer(n) -> n
      s when is_binary(s) -> String.to_integer(s)
    end
  rescue
    _ -> default
  end
end
