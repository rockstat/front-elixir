defmodule RockstatFront.StaticData do
  @moduledoc """
  Preloads static content (web-sdk lib.js etc. from the `static` config
  section, plus index/favicon from priv/static) into `:persistent_term`.
  `prepare_lib/1` prepends the runtime config snippet (TS `rtConfig`).
  """

  require Logger

  alias RockstatFront.Config, as: AppConfig

  @key {__MODULE__, :content}

  @doc """
  Читает статику один раз при старте: файлы из секции static конфига
  (web-sdk lib.js / lib-dev.js) и index.html + favicon.ico из priv/static
  (в TS они были зашиты в исходник байтовыми массивами).
  Отсутствующий файл — предупреждение, не ошибка: маршрут ответит 404.
  """
  def load! do
    from_config =
      AppConfig.get("static", %{})
      |> Enum.reduce(%{}, fn {name, path}, acc ->
        case File.read(path) do
          {:ok, data} ->
            Logger.info("Loaded static file: #{name}/#{path} #{div(byte_size(data), 1024)}kb")
            Map.put(acc, name, data)

          {:error, reason} ->
            Logger.warning("Can not load static file #{name}/#{path}: #{inspect(reason)}")
            acc
        end
      end)

    builtin =
      for name <- ["index.html", "favicon.ico"],
          path = Path.join([:code.priv_dir(:rockstat_front), "static", name]),
          File.exists?(path),
          into: %{} do
        key = name |> String.split(".") |> hd()
        {key, File.read!(path)}
      end

    :persistent_term.put(@key, Map.merge(builtin, from_config))
  end

  def get_item(name), do: Map.get(:persistent_term.get(@key, %{}), name)

  @doc """
  Тело /lib.js: перед кодом web-sdk приклеивается JS-прелюдия с конфигурацией
  (initialUid, клиентские опции) и поправкой клиентских часов. В dev-режиме
  отдаётся lib-dev.js.
  """
  def prepare_lib(params) do
    case get_item(lib_name()) do
      nil -> nil
      lib -> rt_config(params) <> lib
    end
  end

  defp lib_name, do: if(AppConfig.prod?(), do: "lib.js", else: "lib-dev.js")

  defp rt_config(params) do
    now = System.system_time(:millisecond)

    "; if(window[\"rstat4\"]){" <>
      "window[\"rstat4\"]('configure',#{Jason.encode!(params)});" <>
      "window[\"rstat4\"]('setTimeDelta', (new Date()) - (new Date(#{now})));" <>
      "} "
  end
end
