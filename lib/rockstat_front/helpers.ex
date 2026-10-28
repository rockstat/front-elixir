defmodule RockstatFront.Helpers do
  @moduledoc "Ports of src/helpers/*: path parsing, uid validation, cyrb53, flatten_dict etc."

  import Bitwise

  # прозрачный 1x1 gif — тело ответов типа pixel
  @empty_gif Base.decode64!("R0lGODlhAQABAIAAAP///////yH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==")
  def empty_gif, do: @empty_gif

  # валидный uid (flake в десятичной записи): 10-22 цифры
  @uid_re ~r/^[0-9]{10,22}$/
  # допустимые имена service/name из URL
  @naming_re ~r/^[a-zA-Z0-9\._-]{1,50}$/
  # допустимое имя файла для StaticHandler (защита от path traversal)
  @static_fn_re ~r/^[a-zA-Z0-9_-]{1,50}\.[a-zA-Z0-9]{1,5}$/

  def valid_name?(nil), do: false
  def valid_name?(v) when is_binary(v), do: Regex.match?(@naming_re, v)
  def valid_name?(_), do: false

  def valid_static_fn?(v) when is_binary(v), do: Regex.match?(@static_fn_re, v)

  @doc "Returns uid when it is a valid 10-22 digit string, else nil."
  def clean_uid(uid) when is_binary(uid) do
    if Regex.match?(@uid_re, uid), do: uid
  end

  def clean_uid(_), do: nil

  @doc """
  Разбирает путь URL на сегменты: у последнего сегмента отрезается
  расширение (/track/event.gif -> parts [track, event], ext "gif"),
  а сегмент `mark` (обычно "band") удаляется и включает native-режим —
  клиент получит BandResponse как JSON вместо обычного рендера.
  """
  def path_parts(path, mark) do
    # первый элемент после split всегда "" (путь начинается с /) — отбрасываем
    parts = path |> String.split("/") |> tl()

    {parts, ext} =
      case List.pop_at(parts, -1) do
        {nil, rest} ->
          {rest, nil}

        {last, rest} ->
          # ищем расширение по ПОСЛЕДНЕЙ точке (как lastIndexOf в TS),
          # поэтому режем перевёрнутую строку
          case last |> String.reverse() |> String.split(".", parts: 2) do
            [rext, rname] when rname != "" ->
              {rest ++ [String.reverse(rname)], String.reverse(rext)}

            _ ->
              {rest ++ [last], nil}
          end
      end

    native = mark in parts
    %{parts: List.delete(parts, mark), native: native, ext: ext}
  end

  @doc "Origin для CORS: заголовок Origin, иначе scheme://host из Referer, иначе `*`."
  def compute_origin(origin, referer) do
    cond do
      origin not in [nil, ""] ->
        origin

      referer not in [nil, ""] ->
        case URI.parse(referer) do
          %URI{scheme: s, host: h} when is_binary(s) and is_binary(h) -> "#{s}://#{h}"
          _ -> "*"
        end

      true ->
        "*"
    end
  end

  def remove_www("www." <> rest), do: rest
  def remove_www(domain), do: domain

  # Домен для куки при cookieDomain: auto — у поддоменов третьего уровня
  # и глубже отрезается первый сегмент (stats.example.com -> example.com),
  # чтобы кука покрывала весь сайт
  def auto_domain(nil), do: nil

  def auto_domain(domain) do
    parts = domain |> remove_www() |> String.split(".")

    case parts do
      [""] -> nil
      _ when length(parts) > 2 -> parts |> tl() |> Enum.join(".")
      _ -> Enum.join(parts, ".")
    end
  end

  @doc """
  Хэш cyrb53 (bryc) — которым web-sdk подписывает тело запроса (параметр dig).
  Бит-в-бит совместим с JS-оригиналом, включая семантику charCodeAt:
  строка итерируется по UTF-16 code units, а не по байтам UTF-8
  (проверено кросс-тестом с Node, в т.ч. на кириллице и эмодзи).
  """
  def cyrb53(str, seed \\ 0) do
    h1 = bxor(0xDEADBEEF, seed)
    h2 = bxor(0x41C6CE57, seed)

    {h1, h2} =
      for <<ch::little-16 <- :unicode.characters_to_binary(str, :utf8, {:utf16, :little})>>,
        reduce: {h1, h2} do
        {h1, h2} ->
          {imul(bxor(h1, ch), 2_654_435_761), imul(bxor(h2, ch), 1_597_334_677)}
      end

    h1 = imul(bxor(h1, bsr(u32(h1), 16)), 2_246_822_507)
    h1 = bxor(h1, imul(bxor(h2, bsr(u32(h2), 13)), 3_266_489_909))
    h2 = imul(bxor(h2, bsr(u32(h2), 16)), 2_246_822_507)
    h2 = bxor(h2, imul(bxor(h1, bsr(u32(h1), 13)), 3_266_489_909))

    4_294_967_296 * band(2_097_151, u32(h2)) + u32(h1)
  end

  # Эмуляция JS Math.imul (32-битное умножение): в JS операнды ^ приводятся
  # через ToInt32, но для битов xor/умножения достаточно держать
  # промежуточные значения как unsigned 32 — результат идентичен.
  defp imul(a, b), do: u32(u32(a) * u32(b))
  defp u32(v), do: band(v, 0xFFFFFFFF)

  @doc """
  Рекурсивно "сплющивает" вложенную карту, склеивая ключи через `sep`:
  %{"properties" => %{"$os" => "iOS"}} -> %{"properties_s_os" => "iOS"}.
  `$` в ключах заменяется на `s_` (mixpanel-свойства). Списки не разворачиваются.
  """
  def flatten_dict(map, sep \\ "_", prefix \\ "") when is_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      k = String.replace(to_string(k), "$", "s_")

      if is_map(v) do
        Map.merge(acc, flatten_dict(v, sep, prefix <> k <> sep))
      else
        Map.put(acc, prefix <> k, v)
      end
    end)
  end

  @doc """
  Декодирует payload JWT БЕЗ проверки подписи (аналог jsonwebtoken.decode) —
  используется только для извлечения данных из кук в pancake.
  """
  def jwt_decode(token) when is_binary(token) do
    with [_, payload, _] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, data} <- Jason.decode(json) do
      data
    else
      _ -> nil
    end
  end

  def jwt_decode(_), do: nil

  @doc """
  Собирает усечённое сообщение для удалённых энричеров по их props-декларациям:
  getvals(msg, [["ip", "td.ip"], ...]) -> %{"ip" => значение msg.td.ip}
  """
  def getvals(obj, requirements) do
    Map.new(requirements, fn [k, prop] -> {k, get_path(obj, prop)} end)
  end

  # значение по точечному пути ("td.ip") внутри вложенных карт
  def get_path(obj, prop) when is_binary(prop) do
    prop
    |> String.split(".")
    |> Enum.reduce(obj, fn
      key, acc when is_map(acc) -> Map.get(acc, key)
      _key, _acc -> nil
    end)
  end
end
