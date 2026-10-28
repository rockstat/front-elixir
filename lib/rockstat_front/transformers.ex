defmodule RockstatFront.Transformers do
  @moduledoc """
  Transformers, port of src/transformers/*. Each returns
  `{batch_msg, submessages}` — the batch envelope plus extracted events.
  """

  alias RockstatFront.Helpers

  # Граница "2040 год в секундах": timestamp меньше неё считается секундами
  # и домножается на 1000 (мобильные SDK шлют и так, и так)
  @time2040 2_536_696_935

  # — общие куски —

  # Конверт батча: исходное сообщение превращается в событие
  # in.gen.batch.batch с пустым data (само содержимое уходит submsg-ами)
  defp batch_msg(msg) do
    %{
      "id" => msg["id"],
      "time" => msg["time"],
      "key" => "in.gen.batch.batch",
      "service" => "batch",
      "name" => "batch",
      "source_service" => msg["service"],
      "source_name" => msg["name"],
      "channel" => msg["channel"],
      "projectId" => msg["projectId"],
      "uid" => msg["uid"],
      "td" => msg["td"],
      "data" => %{}
    }
  end

  # Общие поля каждого распакованного события: наследует канал/uid/td/project
  # исходного запроса, но получает свой service/name (напр. events_mp_ios)
  defp submsg_base(msg, service, name) do
    %{
      "name" => name,
      "service" => service,
      "key" => "in.gen.#{service}.#{name}",
      "channel" => msg["channel"],
      "td" => msg["td"],
      "projectId" => msg["projectId"],
      "uid" => msg["uid"]
    }
  end

  # Мобильные mixpanel-SDK шлют батч как base64(JSON-массив)
  defp decode_b64_batch(data) do
    with {:ok, raw} <- Base.decode64(to_string(data)),
         {:ok, recs} when is_list(recs) <- Jason.decode(raw) do
      {:ok, recs}
    else
      {:ok, _not_list} -> {:error, "Batch is not a batch"}
      _ -> {:error, "batch decode error"}
    end
  end

  # Служебные поля привязки события к исходному батчу (для склейки в ClickHouse)
  defp batch_fields(data, msg, i) do
    data
    |> Map.put("src", msg["projectId"])
    |> Map.put("batch_timestamp", msg["time"])
    |> Map.put("batch_source_id", msg["id"])
    |> Map.put("batch_event_number", i)
    |> Map.put("source_service", msg["service"])
    |> Map.put("source_name", msg["name"])
  end

  # Клиентское время события: properties_time из mixpanel-свойств, иначе
  # серверное; секунды переводятся в миллисекунды (см. @time2040)
  defp client_time(data, msg) do
    t =
      case data["properties_time"] do
        nil -> msg["time"]
        v -> num(v) || msg["time"]
      end

    if t < @time2040, do: t * 1000, else: t
  end

  defp num(v) when is_number(v), do: v

  defp num(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> if f == trunc(f), do: trunc(f), else: f
      :error -> nil
    end
  end

  defp num(_), do: nil

  # — mixpanel base64-батчи (android и ios отличаются только тем, что ios
  #   переносит поле id в internal_id) —

  defp mp_transform(msg, service) do
    batch = batch_msg(msg)
    base = submsg_base(msg, service, "events")

    case msg["data"] do
      %{"data" => b64} ->
        case decode_b64_batch(b64) do
          {:ok, recs} ->
            subs =
              recs
              |> Enum.with_index()
              |> Enum.map(fn {rec, i} ->
                data =
                  rec
                  |> Helpers.flatten_dict()
                  |> then(fn d ->
                    if service == "events_mp_ios" do
                      d |> Map.put("internal_id", d["id"]) |> Map.put("id", nil)
                    else
                      d
                    end
                  end)
                  |> batch_fields(msg, i)

                base
                |> Map.put("time", client_time(data, msg))
                |> Map.put("data", data)
              end)

            {batch, subs}

          {:error, err} ->
            # битый батч не роняет запрос: конверт уходит с полем err,
            # события не извлекаются (как в TS)
            {put_in(batch, ["data", "err"], err), []}
        end

      _ ->
        {batch, []}
    end
  end

  defmodule MPAndroid do
    def handle(_key, msg), do: RockstatFront.Transformers.mp_android(msg)
  end

  defmodule MPIOS do
    def handle(_key, msg), do: RockstatFront.Transformers.mp_ios(msg)
  end

  defmodule MPIOSNative do
    def handle(_key, msg), do: RockstatFront.Transformers.mp_ios_native(msg)
  end

  defmodule PHNative do
    def handle(_key, msg), do: RockstatFront.Transformers.ph_native(msg)
  end

  defmodule TrackBatch do
    def handle(_key, msg), do: RockstatFront.Transformers.track_batch(msg)
  end

  def mp_android(msg), do: mp_transform(msg, "events_mp_android")
  def mp_ios(msg), do: mp_transform(msg, "events_mp_ios")

  # — ios native: события приходят обычным JSON-массивом в data.data,
  #   без base64; записи без поля event пропускаются —

  def mp_ios_native(msg) do
    batch = batch_msg(msg)
    base = submsg_base(msg, "events_mp_ios", "events")

    case msg["data"] do
      %{"data" => recs} when is_list(recs) ->
        subs =
          recs
          |> Enum.with_index()
          |> Enum.filter(fn {rec, _} -> is_map(rec) and rec["event"] not in [nil, ""] end)
          |> Enum.map(fn {rec, i} ->
            data =
              rec
              |> Helpers.flatten_dict()
              |> then(&(&1 |> Map.put("internal_id", &1["id"]) |> Map.put("id", nil)))
              |> batch_fields(msg, i)

            base
            |> Map.put("time", client_time(data, msg))
            |> Map.put("data", data)
          end)

        {batch, subs}

      _ ->
        {batch, []}
    end
  end

  # — нативный формат PostHog: {api_key, sent_at, batch: [...]};
  #   timestamp события переезжает в origin_timestamp, время события
  #   берётся из него, api_key/sent_at дублируются в каждое событие —

  def ph_native(msg) do
    batch = batch_msg(msg)
    base = submsg_base(msg, "events_ph", "events")

    case msg["data"] do
      %{"batch" => recs} = payload when is_list(recs) ->
        sent_at = parse_ts(payload["sent_at"])
        api_key = payload["api_key"]

        batch =
          batch
          |> put_in(["data", "api_key"], api_key)
          |> put_in(["data", "sent_at"], sent_at)

        subs =
          recs
          |> Enum.with_index()
          |> Enum.filter(fn {rec, _} -> is_map(rec) and rec["event"] not in [nil, ""] end)
          |> Enum.map(fn {rec, i} ->
            flat = Helpers.flatten_dict(rec)
            event_ts = flat["timestamp"]

            data =
              flat
              |> Map.put("timestamp", nil)
              |> Map.put("origin_timestamp", event_ts)
              |> batch_fields(msg, i)
              |> Map.put("sent_at", sent_at)
              |> Map.put("api_key", api_key)

            base
            |> Map.put("time", parse_ts(event_ts) || msg["time"])
            |> Map.put("data", data)
          end)

        {batch, subs}

      _ ->
        {batch, []}
    end
  end

  # — универсальный base64-батч: в отличие от mixpanel-вариантов каждое
  #   событие сохраняет СВОИ service/name из записи (ключ строится по ним) —

  def track_batch(msg) do
    batch = batch_msg(msg)

    base =
      submsg_base(msg, msg["service"], msg["name"])
      |> Map.drop(["name", "key"])

    case msg["data"] do
      %{"data" => b64} ->
        case decode_b64_batch(b64) do
          {:ok, recs} ->
            subs =
              recs
              |> Enum.with_index()
              |> Enum.map(fn {rec, i} ->
                data =
                  rec
                  |> Helpers.flatten_dict()
                  |> Map.put("src", msg["projectId"])
                  |> Map.put("batch_timestamp", msg["time"])
                  |> Map.put("batch_source_id", msg["id"])
                  |> Map.put("batch_event_number", i)
                  |> Map.put("service", rec["service"])

                base
                |> Map.put("name", rec["name"])
                |> Map.put("key", "in.gen.#{rec["service"]}.#{rec["name"]}")
                |> Map.put("data", data)
              end)

            {batch, subs}

          {:error, err} ->
            {put_in(batch, ["data", "err"], err), []}
        end

      _ ->
        {batch, []}
    end
  end

  defp parse_ts(nil), do: nil

  defp parse_ts(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp parse_ts(v) when is_number(v), do: v

  @by_name %{
    "MPAndroidTransformer" => MPAndroid,
    "MPIOSTransformer" => MPIOS,
    "MPIOSNativeTransformer" => MPIOSNative,
    "PHNativeTransformer" => PHNative,
    "TrackBatchTransformer" => TrackBatch
  }

  def by_name, do: @by_name
end
