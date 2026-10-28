defmodule RockstatFront.Http.Router do
  @moduledoc """
  HTTP entry point, port of src/http/http_server.ts `handle`/`route`/`send`.
  Runs as a single Plug under Bandit.
  """

  @behaviour Plug

  require Logger

  alias RockstatFront.{BandResponse, Config, Dispatcher, Helpers, Ids, Metrics, StaticData}

  # Content-type по расширению в URL (/track/event.json → json-парсинг тела,
  # /gif/visit.gif → канал pixel). Имеет приоритет над заголовком Content-Type.
  @ext_content_type %{
    "json" => "application/json",
    "gif" => "image/gif",
    "js" => "text/javascript",
    "html" => "text/html"
  }

  # Лимит тела запроса, как в TS (getRawBody limit: '1mb')
  @body_limit 1_048_576

  @impl true
  def init(opts), do: opts

  # Точка входа каждого HTTP-запроса. Меряет время, ловит любые исключения
  # пайплайна (ответ 500 вместо падения процесса) и отправляет ответ.
  @impl true
  def call(conn, _opts) do
    started = System.monotonic_time(:millisecond)
    Metrics.tick("http.request")

    {resp, conn} =
      try do
        handle(conn)
      rescue
        e ->
          Logger.error("exception caused | handle exec: #{Exception.message(e)}")
          {BandResponse.error(status: 500), conn}
      end

    elapsed = System.monotonic_time(:millisecond) - started
    Metrics.timing("http.request", elapsed)
    send_resp_band(conn, resp, elapsed)
  end

  # — разбор запроса (порт `handle` из http_server.ts) —

  # Готовит всё, что нужно для роутинга: разбирает путь на
  # [service, name, projectId] + расширение + native-флаг (сегмент `band`),
  # валидирует имена, проверяет dig-подпись и читает тело.
  # Возвращает {BandResponse, conn}.
  defp handle(conn) do
    conn = Plug.Conn.fetch_cookies(conn)

    opts = Config.get("http")
    identify = Config.get("identify")
    url_mark = opts["url_mark"] || "band"

    %{parts: parts, native: native, ext: ext} = Helpers.path_parts(conn.request_path, url_mark)
    [url_service, url_name, url_project_id] = Enum.take(parts ++ [nil, nil, nil], 3)

    query = Plug.Conn.Query.decode(conn.query_string || "")

    if illegal_names?(url_service, url_name) do
      Metrics.tick("http.handle_illegal_names")
      {BandResponse.error(status: 400), conn}
    else
      cookies = conn.req_cookies
      services_params = merged_services_params(opts)
      url_service_params = url_service && services_params[url_service]

      content_type =
        @ext_content_type[ext] ||
          first_header(conn, "content-type") ||
          ""

      case check_dig(url_service_params, query) do
        {:error, resp} ->
          {resp, conn}

        {:ok, dig} ->
          case read_request_body(conn, content_type, dig) do
            {:error, resp, conn} ->
              {resp, conn}

            {:ok, body, conn} ->
              route_request(conn, %{
                query: query,
                body: body,
                cookies: cookies,
                identify: identify,
                native: native,
                ext: ext,
                content_type: content_type,
                url_service: url_service,
                url_name: url_name,
                url_project_id: url_project_id,
                url_service_params: url_service_params
              })
          end
      end
    end
  end

  # Собирает структуру RouteOn (как в TS): итоговые service/name с учётом
  # алиасов из конфига, uid из query/body/cookie (или новый flake),
  # pancake-куки, transport data — и навешивает на готовый ответ
  # общие заголовки (CORS, secure, no-cache) и uid-куку.
  defp route_request(conn, ctx) do
    %{query: query, body: body, cookies: cookies, url_service_params: svc_params} = ctx

    # приоритет источников: query -> body -> алиас из конфига -> сегмент URL
    service =
      first_of([
        query["service"],
        body["service"],
        svc_params && svc_params["alias_for"],
        ctx.url_service
      ])

    name = first_of([ctx.url_name, query["name"], body["name"]])
    uid_param = (svc_params && svc_params["uid_param"]) || ctx.identify["param"] || "uid"

    project_id =
      first_of([ctx.url_project_id, query["projectId"], body["projectId"]])
      |> to_int(0)

    pancake = collect_pancake(svc_params, name, cookies)

    # uid: первый валидный (10-22 цифры) из query/body/cookie, иначе новый
    uid =
      Helpers.clean_uid(query[uid_param]) ||
        Helpers.clean_uid(body[uid_param]) ||
        Helpers.clean_uid(cookies[uid_param]) ||
        Ids.flake()

    td = transport_data(conn)
    origin = Helpers.compute_origin(first_header(conn, "origin"), first_header(conn, "referer"))

    route_on = %{
      method: conn.method,
      content_type: ctx.content_type,
      query: query,
      body: body,
      pancake: pancake,
      uid: uid,
      uid_param: uid_param,
      path: conn.request_path,
      ext: ctx.ext,
      service: service,
      name: name,
      project_id: project_id,
      origin: origin,
      td: td
    }

    resp = route(route_on)
    resp = %{resp | native__: ctx.native}

    cookie = uid_cookie(uid_param, uid, td, ctx.identify)

    resp = %{
      resp
      | headers:
          resp.headers ++
            secure_headers() ++
            cors_headers(origin) ++
            no_cache_headers() ++
            [["Set-Cookie", cookie]]
    }

    {resp, conn}
  end

  # — роутинг (порт `route`): клозы матчатся сверху вниз —

  # CORS preflight: отвечаем сразу, не доходя до диспетчера
  defp route(%{method: "OPTIONS", origin: origin}) do
    BandResponse.data(
      headers: cors_headers(origin) ++ cors_answer_headers() ++ cors_additional_headers(),
      data: nil
    )
  end

  # кроме preflight принимаем только GET и POST
  defp route(%{method: m}) when m not in ["GET", "POST"], do: BandResponse.error(status: 400)

  # health-check-шутка из оригинала: 418 I'm a teapot + имя сервиса в заголовке
  defp route(%{path: "/coffee"}) do
    BandResponse.error(
      status: 418,
      headers: [["X-My-Name", Config.get("name", "front")]]
    )
  end

  # web-sdk: отдаём lib.js с приклеенной спереди rtConfig-прелюдией
  # (initialUid + клиентские опции + поправка времени)
  defp route(%{path: "/lib.js"} = ro) do
    client_opts = Config.get(["client", "common"], %{}) || %{}

    params =
      client_opts
      |> Map.put("initialUid", ro.uid)
      |> Map.put("urlMark", Config.get(["http", "url_mark"], "band"))

    case StaticData.prepare_lib(params) do
      nil -> BandResponse.error(status: 404)
      lib -> BandResponse.data(data: {:binary, lib}, content_type: "text/javascript")
    end
  end

  defp route(%{path: "/"}) do
    case StaticData.get_item("index") do
      nil -> BandResponse.error(status: 404)
      html -> BandResponse.data(data: {:binary, html}, content_type: "text/html")
    end
  end

  defp route(%{path: "/favicon.ico"}) do
    case StaticData.get_item("favicon") do
      nil -> BandResponse.error(status: 404)
      icon -> BandResponse.data(data: {:binary, icon}, content_type: "image/x-icon")
    end
  end

  # Основной путь: service + name определены — собираем сообщение шины
  # с ключом in.gen.<service>.<name> и отдаём в Dispatcher
  defp route(%{service: service, name: name} = ro)
       when is_binary(service) and service != "" and is_binary(name) and name != "" do
    key = "in.gen.#{service}.#{name}"

    # запросы картинок (пиксели) помечаются каналом pixel — хендлер
    # track по нему решает отвечать гифкой, а не JSON-ом
    channel = if String.contains?(ro.content_type, "image"), do: "pixel", else: "http"

    msg = %{
      "key" => key,
      "channel" => channel,
      "service" => service,
      "name" => name,
      "ext" => ro.ext,
      "projectId" => ro.project_id,
      "uid_param" => ro.uid_param,
      "uid" => ro.uid,
      "td" => ro.td,
      # payload события: тело + query, query при конфликте побеждает
      "data" => Map.merge(ro.body, ro.query),
      "pancake" => ro.pancake
    }

    Dispatcher.dispatch(key, msg)
  end

  # ничего не подошло — 404
  defp route(ro) do
    Logger.debug("404 request: #{ro.path}")
    BandResponse.error(status: 404)
  end

  # — вспомогательные куски разбора запроса —

  # TS checks the first two path segments against ^[a-zA-Z0-9._-]{1,50}$.
  # Deviation from the TS original: absent/empty segments are allowed here so
  # that "/", "/lib.js" etc. reach their routes (in TS "/" failed this check).
  defp illegal_names?(service, name) do
    Enum.any?([service, name], fn
      nil -> false
      "" -> false
      v -> not Helpers.valid_name?(v)
    end)
  end

  # Объединяет два источника алиасов из конфига: подробный services_params
  # и простую карту sevices_map (away: redir -> %{"alias_for" => "redir"}).
  # services_params при совпадении ключа имеет приоритет.
  defp merged_services_params(opts) do
    base = opts["services_params"] || %{}

    Enum.reduce(opts["sevices_map"] || %{}, base, fn {k, v}, acc ->
      Map.put_new(acc, k, %{"alias_for" => v})
    end)
  end

  # Анти-спам проверка web-sdk: сервис с dig: true требует в query параметр
  # dig = cyrb53-хэш сырого тела. Здесь проверяется только наличие и формат
  # (неотрицательное целое при url_check_websdk); сам хэш сверяется после
  # чтения тела в verify_dig/2.
  defp check_dig(%{"dig" => true} = params, query) do
    case query["dig"] do
      nil ->
        Metrics.tick("http.request_no_dig_required")
        {:error, BandResponse.error(status: 400)}

      dig_str ->
        dig_str = to_string(dig_str)

        if params["url_check_websdk"] && not non_negative_int?(dig_str) do
          Metrics.tick("http.request_hueviy_dig")
          {:error, BandResponse.error(status: 400)}
        else
          {:ok, parse_number(dig_str)}
        end
    end
  end

  # для сервисов без dig-требования проверка пропускается
  defp check_dig(_params, _query), do: {:ok, nil}

  defp non_negative_int?(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 0 -> true
      _ -> false
    end
  end

  defp parse_number(str) do
    case Integer.parse(str) do
      {n, ""} ->
        n

      _ ->
        case Float.parse(str) do
          {f, ""} -> f
          _ -> nil
        end
    end
  end

  # Чтение и разбор тела POST: лимит 1МБ, распаковка gzip по Content-Encoding,
  # сверка dig-хэша с сырым телом, затем парсинг JSON либо urlencoded.
  # Любая ошибка на этом пути -> 400.
  defp read_request_body(%Plug.Conn{method: "POST"} = conn, content_type, dig) do
    with {:ok, raw, conn} <- Plug.Conn.read_body(conn, length: @body_limit),
         {:ok, raw} <- maybe_gunzip(raw, first_header(conn, "content-encoding")),
         :ok <- verify_dig(raw, dig) do
      {:ok, parse_body(raw, content_type), conn}
    else
      # :more = тело больше лимита (read_body вернул только часть)
      {:more, _raw, conn} ->
        Metrics.tick("http.request_no_body")
        {:error, BandResponse.error(status: 400), conn}

      _ ->
        Metrics.tick("http.request_no_body")
        {:error, BandResponse.error(status: 400), conn}
    end
  end

  # не-POST запросы тела не имеют
  defp read_request_body(conn, _content_type, _dig), do: {:ok, %{}, conn}

  defp maybe_gunzip(raw, "gzip") do
    {:ok, :zlib.gunzip(raw)}
  rescue
    _ -> :error
  end

  defp maybe_gunzip(raw, _), do: {:ok, raw}

  defp verify_dig(_raw, nil), do: :ok

  defp verify_dig(raw, dig) do
    if Helpers.cyrb53(raw) == dig do
      :ok
    else
      Logger.info("DIGS not eq")
      :error
    end
  end

  defp parse_body(raw, content_type) do
    if String.contains?(content_type, "json") do
      case Jason.decode(raw) do
        # JSON-массив заворачивается в %{"data" => [...]} (как в TS) —
        # так батчи единообразно попадают в трансформеры
        {:ok, list} when is_list(list) -> %{"data" => list}
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end
    else
      # всё остальное трактуем как application/x-www-form-urlencoded
      Plug.Conn.Query.decode(raw)
    end
  rescue
    _ -> %{}
  end

  # "Pancake" — дополнительный набор кук, который сервис просит прокинуть
  # в сообщение (services_params в конфиге):
  #   collect_cookies — явный список имён кук;
  #   action_params[name].collect_all_cookies — собрать все куки для события,
  #     кроме remove_cookies, а перечисленные в jwt_decode декодировать как JWT
  #     (без проверки подписи).
  defp collect_pancake(nil, _name, _cookies), do: %{}

  defp collect_pancake(svc_params, name, cookies) do
    base =
      case svc_params["collect_cookies"] do
        keys when is_list(keys) ->
          for k <- keys, v = cookies[k], v != nil, into: %{}, do: {k, v}

        _ ->
          %{}
      end

    action = get_in(svc_params, ["action_params", name]) || %{}

    if action["collect_all_cookies"] do
      remove = action["remove_cookies"] || %{}
      jwt_keys = action["jwt_decode"] || %{}

      Enum.reduce(cookies, base, fn {k, v}, acc ->
        cond do
          remove[k] -> acc
          jwt_keys[k] -> Map.put(acc, k, Helpers.jwt_decode(v))
          true -> Map.put(acc, k, v)
        end
      end)
    else
      base
    end
  end

  # Транспортные данные запроса (td в сообщении): реальный IP из заголовков
  # прокси, user-agent, referer и исходные X-Forwarded-* для даунстримов
  defp transport_data(conn) do
    remote_ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    %{
      "ip" => first_header(conn, "x-real-ip") || remote_ip,
      "ua" => first_header(conn, "user-agent"),
      "ref" => first_header(conn, "referer"),
      "host" => first_header(conn, "x-forwarded-host"),
      "xforw" => first_header(conn, "x-forwarded-for"),
      "xrealip" => first_header(conn, "x-real-ip")
    }
  end

  # Идентификационная кука (по умолчанию uid=..., 3 года):
  # domain берётся из X-Forwarded-Host, иначе из конфига identify
  # (cookieDomain: auto -> домен верхнего уровня с точкой)
  defp uid_cookie(param, uid, td, identify) do
    max_age = identify["cookieMaxAge"] || 3 * 365 * 24 * 60 * 60

    expires =
      DateTime.utc_now()
      |> DateTime.add(max_age, :second)
      |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

    domain = td["host"] || cookie_domain(identify)

    [
      "#{param}=#{uid || "0"}",
      "Expires=#{expires}",
      "Path=#{identify["cookiePath"] || "/"}",
      domain && "Domain=#{domain}",
      "HttpOnly",
      "Secure",
      "SameSite=None"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("; ")
  end

  defp cookie_domain(identify) do
    case identify["cookieDomain"] do
      "auto" ->
        case identify["domain"] do
          nil -> nil
          domain -> "." <> (Helpers.auto_domain(domain) || domain)
        end

      other ->
        other
    end
  end

  # — отправка ответа (порт `send` из http_server.ts) —

  # Превращает BandResponse в HTTP-ответ: рендерит тело по type__,
  # добавляет Location для редиректов и X-Response-Time
  defp send_resp_band(conn, %BandResponse{} = resp, elapsed) do
    {raw, content_type} = render_body(resp)

    location =
      if resp.type__ == "redirect" and resp.native__ != true,
        do: [["Location", resp.location]],
        else: []

    headers =
      resp.headers ++
        location ++
        [
          ["X-Response-Time", to_string(elapsed)],
          ["Content-Type", content_type]
        ]

    conn =
      Enum.reduce(headers, conn, fn
        [h, v], acc -> put_header(acc, h, v)
        {h, v}, acc -> put_header(acc, h, v)
      end)

    Plug.Conn.send_resp(conn, resp.statusCode, raw)
  end

  # native-режим (сегмент `band` в URL): клиент получает весь BandResponse
  # как JSON вместо обычного рендера — редирект не исполняется, а описывается
  defp render_body(%BandResponse{native__: true} = resp),
    do: {BandResponse.native_json(resp), "application/json"}

  defp render_body(%BandResponse{type__: "data"} = resp) do
    case resp.data do
      nil -> {"", resp.contentType || "application/json"}
      {:binary, bin} -> {bin, resp.contentType || "application/octet-stream"}
      data when is_map(data) or is_list(data) -> {Jason.encode!(data), "application/json"}
      other -> {to_string(other), resp.contentType || "application/json"}
    end
  end

  defp render_body(%BandResponse{type__: "redirect"}), do: {"", "text/html"}

  defp render_body(%BandResponse{type__: "pixel"}), do: {Helpers.empty_gif(), "image/gif"}

  defp render_body(%BandResponse{type__: "error"} = resp),
    do: {Jason.encode!(%{"message" => resp.errorMessage}), "application/json"}

  defp render_body(_resp), do: {"", "application/json"}

  defp put_header(conn, h, v) do
    name = String.downcase(to_string(h))
    value = to_string(v)

    case name do
      # the server computes it from the body itself
      "content-length" -> conn
      "set-cookie" -> Plug.Conn.prepend_resp_headers(conn, [{name, value}])
      _ -> Plug.Conn.put_resp_header(conn, name, value)
    end
  end

  # — наборы заголовков (порт helpers/http.ts) —

  defp secure_headers do
    [["X-Frame-Options", "SAMEORIGIN"], ["X-XSS-Protection", "1"]]
  end

  defp cors_headers(origin) do
    [
      ["Access-Control-Allow-Origin", origin],
      ["Access-Control-Allow-Credentials", "true"],
      ["Access-Control-Expose-Headers", "Content-Length,Content-Type"]
    ]
  end

  defp cors_answer_headers do
    [
      ["Access-Control-Allow-Methods", "POST,GET"],
      [
        "Access-Control-Allow-Headers",
        "X-Requested-With,Access-Control-Allow-Origin,Content-Type,Authorization,Accept"
      ],
      ["Access-Control-Max-Age-Scope", "domain"],
      ["Access-Control-Max-Age", "86400"]
    ]
  end

  defp cors_additional_headers do
    [
      ["Content-Length", "0"],
      ["Cache-Control", "max-age=3600"],
      ["Vary", "Origin"]
    ]
  end

  defp no_cache_headers do
    [
      ["Pragma", "no-cache"],
      ["Cache-Control", "no-cache, no-store, must-revalidate"],
      ["Expires", "Mon, 01 Jan 1990 21:00:12 GMT"],
      ["Last-Modified", "Sun, 17 May 1998 03:44:30 GMT"]
    ]
  end

  # первое значение заголовка запроса или nil
  defp first_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [v | _] -> v
      [] -> nil
    end
  end

  # первое непустое значение из списка кандидатов
  defp first_of(list), do: Enum.find(list, &(&1 not in [nil, ""]))

  defp to_int(nil, default), do: default

  defp to_int(v, default) do
    case Integer.parse(to_string(v)) do
      {n, _} -> n
      :error -> default
    end
  end
end
