defmodule RockstatFront.Config do
  @moduledoc """
  Loads `config/*.yml`, rendered through EEx (the TS version used EJS with the
  same `<%= %>` delimiters), merges the env-specific section (`production` /
  `dev`) over the common part and stores the result in `:persistent_term`.
  """

  @key {__MODULE__, :config}

  @doc """
  Загружает конфиг при старте приложения:
  1. все config/**/*.yml склеиваются и рендерятся через EEx
     (доступны @env — системное окружение и @version — версия приложения);
  2. YAML-документы сливаются с глубоким мержем;
  3. секция production/dev (по NODE_ENV) накладывается поверх общей части.
  """
  def load! do
    dir = Path.join(app_dir(), "config")

    rendered =
      Path.wildcard(Path.join(dir, "**/*.yml"))
      |> Enum.map(&File.read!/1)
      |> Enum.join("\n")
      |> EEx.eval_string(assigns: [env: System.get_env(), version: version()])

    docs =
      rendered
      |> YamlElixir.read_all_from_string!()
      |> Enum.reject(&is_nil/1)

    merged = Enum.reduce(docs, %{}, &deep_merge(&2, &1))
    {env_cfg, common} = Map.split(merged, ["production", "dev"])

    config =
      common
      |> deep_merge(Map.get(env_cfg, env_section(), %{}) || %{})
      |> Map.put("env", env())

    # persistent_term: чтение бесплатно из любого процесса,
    # запись происходит один раз при старте
    :persistent_term.put(@key, config)
    config
  end

  def all, do: :persistent_term.get(@key)

  @doc "Секция или вложенный путь конфига: `get(\"http\")`, `get([\"http\", \"port\"])`."
  def get(path, default \\ nil)
  def get(path, default) when is_list(path), do: get_in(all(), path) || default
  def get(key, default), do: Map.get(all(), key, default)

  # Окружение в терминах платформы: NODE_ENV production/prod -> "production",
  # stage -> "stage", всё остальное -> "dev" (как AppConfig.env в rock-me-ts)
  def env do
    case System.get_env("NODE_ENV") || System.get_env("MIX_ENV") do
      e when e in ["production", "prod"] -> "production"
      "stage" -> "stage"
      _ -> "dev"
    end
  end

  def prod?, do: env() == "production"

  defp env_section, do: if(prod?(), do: "production", else: "dev")

  defp version, do: Application.spec(:rockstat_front, :vsn) |> to_string()

  # В release-сборке рабочая директория может отличаться — если рядом
  # нет config/, берём каталог приложения
  defp app_dir do
    if File.dir?("config"), do: File.cwd!(), else: Application.app_dir(:rockstat_front)
  end

  # глубокий мерж: вложенные карты сливаются рекурсивно, прочее — правое побеждает
  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _k, l, r -> deep_merge(l, r) end)
  end

  defp deep_merge(_left, right), do: right
end
