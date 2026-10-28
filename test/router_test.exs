defmodule RockstatFront.RouterTest do
  @moduledoc """
  Интеграционные тесты HTTP-слоя через Plug.Test: приложение в тестовом
  окружении стартует без Bandit (config :rockstat_front, server: false),
  роутер вызывается напрямую. Redis не требуется.
  """

  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]

  alias RockstatFront.Helpers
  alias RockstatFront.Http.Router

  defp request(conn), do: Router.call(conn, [])

  defp json(conn), do: Jason.decode!(conn.resp_body)

  describe "служебные маршруты" do
    test "GET / отдаёт заставку" do
      conn = request(conn(:get, "/"))
      assert conn.status == 200
      assert {"content-type", "text/html"} in conn.resp_headers
      assert conn.resp_body =~ "Rockstat"
    end

    test "GET /health — healthcheck без пайплайна" do
      conn = request(conn(:get, "/health"))
      assert conn.status == 200
      assert json(conn) == %{"status" => "ok"}
    end

    test "GET /coffee — 418 с именем сервиса" do
      conn = request(conn(:get, "/coffee"))
      assert conn.status == 418
      assert Plug.Conn.get_resp_header(conn, "x-my-name") != []
    end

    test "OPTIONS — CORS preflight" do
      conn = request(put_req_header(conn(:options, "/track/event"), "origin", "https://site.io"))
      assert conn.status == 200
      assert {"access-control-allow-origin", "https://site.io"} in conn.resp_headers
      assert {"access-control-allow-methods", "POST,GET"} in conn.resp_headers
    end

    test "методы кроме GET/POST/OPTIONS -> 400" do
      assert request(conn(:put, "/track/event")).status == 400
    end
  end

  describe "трекинг" do
    test "GET /track/<event> отвечает id события" do
      conn = request(conn(:get, "/track/pageview?uid=12345678901"))
      assert conn.status == 200
      assert %{"id" => id} = json(conn)
      assert id =~ ~r/^[0-9]+$/
    end

    test "валидный uid из query попадает в Set-Cookie" do
      conn = request(conn(:get, "/track/pageview?uid=12345678901"))
      [cookie] = Plug.Conn.get_resp_header(conn, "set-cookie")
      assert cookie =~ "uid=12345678901"
      assert cookie =~ "SameSite=None"
      assert cookie =~ "HttpOnly"
    end

    test "без uid генерируется новый" do
      conn = request(conn(:get, "/track/pageview"))
      [cookie] = Plug.Conn.get_resp_header(conn, "set-cookie")
      assert cookie =~ ~r/uid=[0-9]{10,22}/
    end

    test "POST с JSON-телом" do
      conn =
        conn(:post, "/track/event", ~s({"page":"/x"}))
        |> put_req_header("content-type", "application/json")
        |> request()

      assert conn.status == 200
      assert %{"id" => _} = json(conn)
    end

    test "запрос .gif получает гифку (канал pixel)" do
      conn = request(conn(:get, "/track/visit.gif"))
      assert conn.status == 200
      assert {"content-type", "image/gif"} in conn.resp_headers
      assert binary_part(conn.resp_body, 0, 3) == "GIF"
    end
  end

  describe "сервисы" do
    test "алиас /gif -> pixel" do
      conn = request(conn(:get, "/gif/visit"))
      assert {"content-type", "image/gif"} in conn.resp_headers
    end

    test "редирект по параметру to (алиас /away)" do
      conn = request(conn(:get, "/away/go?to=https://example.com"))
      assert conn.status == 302
      assert {"location", "https://example.com"} in conn.resp_headers
    end

    test "редирект без to -> 400" do
      assert request(conn(:get, "/redir/go")).status == 400
    end

    test "/hello/ping -> pong" do
      assert json(request(conn(:get, "/hello/ping"))) == %{"message" => "pong"}
    end

    test "native-режим: сегмент band превращает ответ в JSON-описание" do
      conn = request(conn(:get, "/band/redir/go?to=https://example.com"))
      assert conn.status == 302

      assert json(conn) == %{
               "type__" => "redirect",
               "statusCode" => 302,
               "location" => "https://example.com"
             }

      # заголовок Location в native-режиме не ставится
      assert Plug.Conn.get_resp_header(conn, "location") == []
    end

    test "недопустимые символы в имени сервиса -> 400" do
      assert request(conn(:get, "/bad%20name/x")).status == 400
    end

    test "неизвестный сервис принят с дефолтным ответом (key/id/uid)" do
      conn = request(conn(:get, "/nosuch/event?uid=12345678901"))
      assert conn.status == 200
      assert %{"key" => "in.gen.nosuch.event", "uid" => "12345678901"} = json(conn)
    end
  end

  describe "dig-подпись (/t4k -> track)" do
    @body ~s({"page":"/x"})

    defp post_t4k(dig_qs, body) do
      conn(:post, "/t4k/event#{dig_qs}", body)
      |> put_req_header("content-type", "application/json")
      |> request()
    end

    test "корректный dig принимается" do
      conn = post_t4k("?dig=#{Helpers.cyrb53(@body)}", @body)
      assert conn.status == 200
      assert %{"id" => _} = json(conn)
    end

    test "без dig -> 400" do
      assert post_t4k("", @body).status == 400
    end

    test "неверный dig -> 400" do
      assert post_t4k("?dig=123", @body).status == 400
    end

    test "dig не целое -> 400 (url_check_websdk)" do
      assert post_t4k("?dig=12.5", @body).status == 400
    end

    test "битый UTF-8 в теле с dig -> 400, а не 500" do
      assert post_t4k("?dig=123", <<0xFF, 0xFE, 0x01>>).status == 400
    end
  end

  describe "тело запроса" do
    test "gzip-тело распаковывается" do
      conn =
        conn(:post, "/track/event", :zlib.gzip(~s({"gz":"yes"})))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("content-encoding", "gzip")
        |> request()

      assert conn.status == 200
    end

    test "gzip-бомба отклоняется по распакованному размеру" do
      # ~2 МБ нулей сжимаются в ~2 КБ: сжатое проходит лимит,
      # распакованное (>1 МБ) должно быть отвергнуто
      bomb = :zlib.gzip(:binary.copy(<<0>>, 2_000_000))
      assert byte_size(bomb) < 10_000

      conn =
        conn(:post, "/track/event", bomb)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("content-encoding", "gzip")
        |> request()

      assert conn.status == 400
    end

    test "JSON-массив заворачивается в data (путь батчей)" do
      recs = [%{"event" => "e1"}]

      conn =
        conn(:post, "/ios/track", Jason.encode!(%{"data" => recs}))
        |> put_req_header("content-type", "application/json")
        |> request()

      assert conn.status == 200
    end
  end

  describe "общие заголовки" do
    test "CORS, secure и no-cache на обычном ответе" do
      conn = request(put_req_header(conn(:get, "/track/x"), "origin", "https://site.io"))

      assert {"access-control-allow-origin", "https://site.io"} in conn.resp_headers
      assert {"x-frame-options", "SAMEORIGIN"} in conn.resp_headers
      assert {"cache-control", "no-cache, no-store, must-revalidate"} in conn.resp_headers
      assert Plug.Conn.get_resp_header(conn, "x-response-time") != []
    end

    test "origin берётся из Referer при отсутствии Origin" do
      conn = request(put_req_header(conn(:get, "/track/x"), "referer", "https://ref.io/page"))
      assert {"access-control-allow-origin", "https://ref.io"} in conn.resp_headers
    end
  end
end
