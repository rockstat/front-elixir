defmodule RockstatFront.TransformersTest do
  use ExUnit.Case, async: true

  alias RockstatFront.Transformers

  # базовое входящее сообщение, как его собирает роутер
  defp msg(data) do
    %{
      "id" => "100",
      "time" => 1_793_211_965_000,
      "key" => "in.gen.x.y",
      "service" => "x",
      "name" => "y",
      "channel" => "http",
      "projectId" => 5,
      "uid" => "12345678901",
      "td" => %{"ip" => "1.2.3.4"},
      "data" => data
    }
  end

  describe "ph_native/1 (PostHog)" do
    test "конверт + события с origin_timestamp и batch-полями" do
      data = %{
        "api_key" => "phk",
        "sent_at" => "2026-01-01T00:00:10.000Z",
        "batch" => [
          %{
            "event" => "signup",
            "properties" => %{"$os" => "iOS"},
            "timestamp" => "2026-01-01T00:00:00.000Z"
          },
          %{"no_event" => true},
          %{"event" => "buy", "timestamp" => "2026-01-01T00:00:05.000Z"}
        ]
      }

      {batch, subs} = Transformers.ph_native(msg(data))

      assert batch["key"] == "in.gen.batch.batch"
      assert batch["data"]["api_key"] == "phk"
      # записи без event пропускаются
      assert length(subs) == 2

      [signup, _buy] = subs
      assert signup["key"] == "in.gen.events_ph.events"
      assert signup["data"]["event"] == "signup"
      assert signup["data"]["properties_s_os"] == "iOS"
      assert signup["data"]["origin_timestamp"] == "2026-01-01T00:00:00.000Z"
      assert signup["data"]["timestamp"] == nil
      assert signup["data"]["batch_source_id"] == "100"
      assert signup["data"]["batch_event_number"] == 0
      # время события — из его timestamp
      assert signup["time"] == 1_767_225_600_000
    end
  end

  describe "mp_ios/1 (Mixpanel iOS, base64)" do
    test "распаковывает base64-батч, переносит id в internal_id, секунды -> мс" do
      recs = [%{"event" => "login", "id" => "evt1", "properties" => %{"time" => 1_761_650_000}}]
      data = %{"data" => Base.encode64(Jason.encode!(recs))}

      {_batch, [sub]} = Transformers.mp_ios(msg(data))

      assert sub["key"] == "in.gen.events_mp_ios.events"
      assert sub["data"]["internal_id"] == "evt1"
      assert sub["data"]["id"] == nil
      # properties_time в секундах -> миллисекунды
      assert sub["time"] == 1_761_650_000_000
      assert sub["data"]["src"] == 5
    end

    test "битый base64 не роняет: конверт уходит с err, событий нет" do
      {batch, subs} = Transformers.mp_ios(msg(%{"data" => "!!!not-base64!!!"}))

      assert subs == []
      assert batch["data"]["err"] != nil
    end
  end

  describe "mp_ios_native/1 (массив без base64)" do
    test "берёт события из data.data, пропускает записи без event" do
      data = %{"data" => [%{"event" => "e1", "id" => "a"}, %{"bad" => true}]}

      {_batch, subs} = Transformers.mp_ios_native(msg(data))

      assert [%{"data" => %{"event" => "e1", "internal_id" => "a"}}] = subs
    end
  end

  describe "mp_android/1" do
    test "события получают сервис events_mp_android" do
      recs = [%{"event" => "tap"}]
      data = %{"data" => Base.encode64(Jason.encode!(recs))}

      {_batch, [sub]} = Transformers.mp_android(msg(data))

      assert sub["service"] == "events_mp_android"
      # без properties_time время берётся серверное (уже в мс)
      assert sub["time"] == 1_793_211_965_000
    end
  end

  describe "track_batch/1" do
    test "каждое событие сохраняет свои service/name" do
      recs = [%{"service" => "svc1", "name" => "ev1", "v" => 1}]
      data = %{"data" => Base.encode64(Jason.encode!(recs))}

      {_batch, [sub]} = Transformers.track_batch(msg(data))

      assert sub["key"] == "in.gen.svc1.ev1"
      assert sub["name"] == "ev1"
      assert sub["data"]["v"] == 1
    end
  end
end
