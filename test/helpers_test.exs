defmodule RockstatFront.HelpersTest do
  use ExUnit.Case, async: true

  alias RockstatFront.Helpers

  describe "cyrb53/2" do
    # эталонные значения получены из JS-оригинала (bryc) в Node
    test "совпадает с JS-реализацией бит-в-бит" do
      assert Helpers.cyrb53(~s({"a":1})) == 4_561_562_304_108_614
      assert Helpers.cyrb53("hello world") == 3_259_054_761_512_980
    end

    test "юникод хэшируется по UTF-16 code units, как charCodeAt" do
      assert Helpers.cyrb53("тест юникода 😀") == 8_848_540_200_885_583
    end

    test "падает на невалидном UTF-8 (роутер отвечает 400)" do
      assert_raise ArgumentError, fn -> Helpers.cyrb53(<<0xFF, 0xFE, 0x01>>) end
    end
  end

  describe "path_parts/2" do
    test "разбирает сервис/имя и расширение" do
      assert Helpers.path_parts("/track/event.gif", "band") ==
               %{parts: ["track", "event"], native: false, ext: "gif"}
    end

    test "расширение ищется по последней точке" do
      assert %{parts: ["static", "file.min"], ext: "js"} =
               Helpers.path_parts("/static/file.min.js", "band")
    end

    test "сегмент band включает native-режим и выкидывается из пути" do
      assert Helpers.path_parts("/band/redir/go", "band") ==
               %{parts: ["redir", "go"], native: true, ext: nil}
    end

    test "корень" do
      assert %{parts: [""], native: false, ext: nil} = Helpers.path_parts("/", "band")
    end
  end

  describe "clean_uid/1" do
    test "принимает только 10-22 цифры" do
      assert Helpers.clean_uid("12345678901") == "12345678901"
      assert Helpers.clean_uid("123") == nil
      assert Helpers.clean_uid("not-a-uid-12345") == nil
      assert Helpers.clean_uid(nil) == nil
      assert Helpers.clean_uid(%{"x" => 1}) == nil
    end
  end

  describe "auto_domain/1" do
    test "у поддоменов отрезается первый сегмент" do
      assert Helpers.auto_domain("stats.example.com") == "example.com"
      assert Helpers.auto_domain("example.com") == "example.com"
      assert Helpers.auto_domain("www.example.com") == "example.com"
    end
  end

  describe "flatten_dict/3" do
    test "сплющивает вложенность и заменяет $ на s_" do
      input = %{"event" => "e", "properties" => %{"$os" => "iOS", "nested" => %{"a" => 1}}}

      assert Helpers.flatten_dict(input) == %{
               "event" => "e",
               "properties_s_os" => "iOS",
               "properties_nested_a" => 1
             }
    end

    test "списки не разворачиваются" do
      assert Helpers.flatten_dict(%{"a" => [1, 2]}) == %{"a" => [1, 2]}
    end
  end

  describe "jwt_decode/1" do
    test "декодирует payload без проверки подписи" do
      # {"alg":"HS256"}.{"sub":"42"}.подпись
      token =
        Base.url_encode64(~s({"alg":"HS256"}), padding: false) <>
          "." <> Base.url_encode64(~s({"sub":"42"}), padding: false) <> ".sig"

      assert Helpers.jwt_decode(token) == %{"sub" => "42"}
    end

    test "мусор даёт nil" do
      assert Helpers.jwt_decode("garbage") == nil
    end
  end

  describe "getvals/2" do
    test "извлекает значения по точечным путям" do
      msg = %{"uid" => "1", "td" => %{"ip" => "1.2.3.4"}}

      assert Helpers.getvals(msg, [["uid", "uid"], ["ip", "td.ip"], ["no", "a.b"]]) ==
               %{"uid" => "1", "ip" => "1.2.3.4", "no" => nil}
    end
  end

  describe "compute_origin/2" do
    test "Origin приоритетнее Referer, без обоих — *" do
      assert Helpers.compute_origin("https://a.io", "https://b.io/page") == "https://a.io"
      assert Helpers.compute_origin(nil, "https://b.io/page") == "https://b.io"
      assert Helpers.compute_origin(nil, nil) == "*"
    end
  end
end
