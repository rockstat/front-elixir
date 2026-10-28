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
    RockstatFront.Ids.setup!()
    configure_logger(config)

    http = config["http"] || %{}
    port = to_int(http["port"], 8080)
    host = http["host"] || "0.0.0.0"

    Logger.info(
      "Starting #{config["name"]} v#{config["version"]} (#{RockstatFront.Config.env()})"
    )

    # Порядок детей важен: Rpc нужен Dispatcher-у (регистрирует методы
    # в init), :redix — энричеру UserData, TaskSup — broadcast-рассылке
    children = [
      # супервизор фоновых задач (broadcast, энричеры, локальные RPC-методы)
      {Task.Supervisor, name: RockstatFront.TaskSup},
      RockstatFront.Metrics,
      # общее Redis-соединение для команд (HGETALL/HSET в UserData)
      {Redix,
       {RockstatFront.Config.get(["redis", "dsn"], "redis://127.0.0.1:6379"), [name: :redix]}},
      RockstatFront.Rpc,
      RockstatFront.Dispatcher
    ]

    # в тестовом окружении (config :rockstat_front, server: false)
    # HTTP-листener не поднимается
    children =
      if Application.get_env(:rockstat_front, :server, true) do
        Logger.info("HTTP transport #{host}:#{port}")

        children ++
          [
            {
              Bandit,
              # держим idle keep-alive соединения дольше, чем upstream
              # keepalive_timeout у nginx (60с по умолчанию), иначе
              # возможны 502 на гонке закрытия
              plug: RockstatFront.Http.Router,
              scheme: :http,
              ip: parse_ip(host),
              port: port,
              thousand_island_options: [read_timeout: 75_000]
            }
          ]
      else
        children
      end

    opts = [strategy: :one_for_one, name: RockstatFront.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Применяет log.level из YAML-конфига (куда он попадает из LOG_LEVEL)
  defp configure_logger(config) do
    level =
      case get_in(config, ["log", "level"]) do
        l when l in ["debug", "info", "notice", "warning", "error", "critical"] ->
          String.to_existing_atom(l)

        # pino-имя уровня из старых конфигов
        "warn" ->
          :warning

        _ ->
          :info
      end

    Logger.configure(level: level)
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
