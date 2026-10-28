defmodule RockstatFront.BandResponse do
  @moduledoc """
  BandResponse struct, same shape as rock-me-ts `structs/response.ts`.
  `type__` is one of "data" | "pixel" | "redirect" | "error" | "static".
  """

  # Имена полей сохранены как в TS (включая suffix __) — структура
  # сериализуется на провод в native-режиме и приходит от удалённых сервисов
  defstruct type__: "data",
            statusCode: 200,
            headers: [],
            data: nil,
            contentType: nil,
            location: nil,
            errorMessage: nil,
            # native-режим: отдать клиенту весь response как JSON
            native__: false

  @type t :: %__MODULE__{}

  @descriptions %{
    200 => "Ok",
    204 => "No Content",
    400 => "Bad Request",
    404 => "Not Found",
    418 => "I'm a teapot",
    500 => "Internal Error",
    302 => "Temporary Redirect",
    301 => "Temporary Redirect",
    303 => "See Others"
  }

  def data(opts \\ []) do
    %__MODULE__{
      type__: "data",
      statusCode: opts[:status] || 200,
      headers: opts[:headers] || [],
      contentType: opts[:content_type],
      data: Keyword.get(opts, :data, %{})
    }
  end

  def pixel(opts \\ []) do
    %__MODULE__{type__: "pixel", statusCode: opts[:status] || 200, headers: opts[:headers] || []}
  end

  def redirect(location, opts \\ []) do
    %__MODULE__{
      type__: "redirect",
      statusCode: opts[:status] || 302,
      headers: opts[:headers] || [],
      location: location
    }
  end

  def error(opts \\ []) do
    status = opts[:status] || 500

    %__MODULE__{
      type__: "error",
      statusCode: status,
      headers: opts[:headers] || [],
      errorMessage: opts[:message] || @descriptions[status] || "Unknown Status"
    }
  end

  @doc "Ответ из сырой карты RPC-результата с `type__` (пришёл от удалённого сервиса)."
  def from_map(%{"type__" => type} = map) do
    %__MODULE__{
      type__: type,
      statusCode: map["statusCode"] || 200,
      headers: map["headers"] || [],
      data: map["data"],
      contentType: map["contentType"],
      location: map["location"],
      errorMessage: map["errorMessage"]
    }
  end

  @doc """
  JSON для native-режима: весь ответ без headers (как `const {headers, ...rest}`
  в TS `send`) — поля добавляются только осмысленные для типа.
  """
  def native_json(%__MODULE__{} = resp) do
    %{"type__" => resp.type__, "statusCode" => resp.statusCode}
    |> maybe_put("data", resp.type__ == "data", resp.data)
    |> maybe_put(
      "contentType",
      resp.type__ == "data" and resp.contentType != nil,
      resp.contentType
    )
    |> maybe_put("location", resp.type__ == "redirect", resp.location)
    |> maybe_put("errorMessage", resp.type__ == "error", resp.errorMessage)
    |> Jason.encode!()
  end

  defp maybe_put(map, _k, false, _v), do: map
  defp maybe_put(map, k, true, v), do: Map.put(map, k, v)
end
