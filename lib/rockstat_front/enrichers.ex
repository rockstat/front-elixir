defmodule RockstatFront.Enrichers do
  @moduledoc "Internal enrichers. Each is `handle(key, msg) :: map` merged into msg data."

  defmodule UserData do
    @moduledoc """
    Stores/loads per-uid data in a redis hash `s:<uid>` (port of
    enrichers/userdata.ts). On `userdata.update` writes fields and sets TTL,
    otherwise returns `%{"stored" => data}` when something is saved.
    """

    require Logger

    @default_ttl 24 * 60 * 60 * 30

    def handle(_key, %{"uid" => uid} = msg) when is_binary(uid) and uid != "" do
      skey = "s:" <> uid

      # событие userdata.update пишет данные, любое другое — читает
      if msg["service"] == "userdata" and msg["name"] == "update" and is_map(msg["data"]) do
        update(skey, msg["data"])
      else
        load(skey)
      end
    end

    # без uid обогащать нечего
    def handle(_key, _msg), do: %{}

    # Запись: каждое поле data (кроме служебных uid/ttl) кладётся в хэш
    # отдельным ключом с JSON-сериализованным значением + выставляется TTL
    defp update(skey, data) do
      pairs =
        data
        |> Enum.reject(fn {k, _} -> k in ["uid", "ttl"] end)
        |> Enum.flat_map(fn {k, v} -> [k, Jason.encode!(v)] end)

      ttl = data["ttl"] || @default_ttl

      if pairs != [] do
        with {:ok, _} <- Redix.command(:redix, ["HMSET", skey | pairs]),
             {:ok, _} <- Redix.command(:redix, ["EXPIRE", skey, to_string(ttl)]) do
          :ok
        else
          {:error, reason} -> Logger.error("userdata update failed: #{inspect(reason)}")
        end
      end

      %{}
    end

    # Чтение: HGETALL возвращает плоский список [k1, v1, k2, v2, ...] —
    # собираем обратно в карту, значения десериализуем из JSON
    defp load(skey) do
      case Redix.command(:redix, ["HGETALL", skey]) do
        {:ok, flat} when is_list(flat) and flat != [] ->
          stored =
            flat
            |> Enum.chunk_every(2)
            |> Map.new(fn [k, v] ->
              {k,
               case Jason.decode(v) do
                 {:ok, decoded} -> decoded
                 _ -> v
               end}
            end)

          %{"stored" => stored}

        _ ->
          %{}
      end
    end
  end

  @by_name %{"UserDataEnricher" => UserData}

  def by_name, do: @by_name
end
