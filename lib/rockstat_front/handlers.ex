defmodule RockstatFront.Handlers do
  @moduledoc "Internal handlers, port of src/handlers/*. Each is `handle(key, msg) :: BandResponse`."

  alias RockstatFront.{BandResponse, Helpers}

  # отвечает прозрачной гифкой 1x1 на любой запрос
  defmodule Pixel do
    def handle(_key, _msg), do: RockstatFront.BandResponse.pixel()
  end

  # 302-редирект на адрес из параметра `to` (сервисы away/go из конфига)
  defmodule Redirect do
    def handle(_key, %{"data" => %{"to" => to}}) when is_binary(to) and to != "" do
      RockstatFront.BandResponse.redirect(to)
    end

    def handle(_key, _msg) do
      RockstatFront.BandResponse.error(status: 400, message: ~s(Parameter "to" is required))
    end
  end

  # Основной трекинг-хендлер: формат ответа зависит от канала —
  # пиксельные запросы получают гифку, http — JSON с id события
  defmodule Track do
    def handle(_key, %{"channel" => "pixel"}), do: RockstatFront.BandResponse.pixel()

    def handle(_key, %{"channel" => "http"} = msg) do
      RockstatFront.BandResponse.data(data: %{"id" => msg["id"]})
    end

    def handle(_key, %{"channel" => "ws"} = msg) do
      case msg["name"] do
        "ping" -> RockstatFront.BandResponse.data(data: %{"message" => "pong"})
        "hello" -> RockstatFront.BandResponse.data(data: %{"message" => "hi"})
        _ -> RockstatFront.BandResponse.data(data: %{"id" => msg["id"]})
      end
    end

    def handle(_key, _msg), do: RockstatFront.BandResponse.error(status: 404)
  end

  # ping/pong для проверки живости
  defmodule Hello do
    def handle(_key, %{"name" => "ping"}),
      do: RockstatFront.BandResponse.data(data: %{"message" => "pong"})

    def handle(_key, %{"name" => "hello"}),
      do: RockstatFront.BandResponse.data(data: %{"message" => "hi"})

    def handle(_key, _msg), do: RockstatFront.BandResponse.error(status: 404)
  end

  # Раздача файлов из каталога public/ (/static/<имя>.<расширение>);
  # имя жёстко валидируется — точки и слэши в нём запрещены
  defmodule Static do
    def handle(_key, %{"ext" => ext} = msg) when is_binary(ext) and ext != "" do
      fn_ = "#{msg["name"]}.#{ext}"

      if RockstatFront.Helpers.valid_static_fn?(fn_) do
        case File.read(Path.join("public", fn_)) do
          {:ok, data} ->
            RockstatFront.BandResponse.data(
              data: {:binary, data},
              content_type: MIME.type(ext)
            )

          {:error, _} ->
            RockstatFront.BandResponse.error(
              status: 400,
              message: "Can not find the requested file"
            )
        end
      else
        RockstatFront.BandResponse.error(status: 400, message: "Invalid file name")
      end
    end

    def handle(_key, _msg),
      do: RockstatFront.BandResponse.error(status: 400, message: "The file extension is missing")
  end

  @doc """
  Фолбэк, когда для ключа нет ни внутреннего, ни удалённого обработчика
  (TS defaultHandler): событие всё равно принято (прошло enrich и уйдёт
  в broadcast), клиенту возвращаются key/id/uid.
  """
  def default(key, msg) do
    BandResponse.data(data: %{"key" => key, "id" => msg["id"], "uid" => msg["uid"]})
  end

  # имена из секции bus.handlers конфига -> модули
  @by_name %{
    "PixelHandler" => Pixel,
    "RedirectHandler" => Redirect,
    "TrackHandler" => Track,
    "HelloHandler" => Hello,
    "StaticHandler" => Static
  }

  def by_name, do: @by_name

  # silence unused alias warning
  _ = Helpers
end
