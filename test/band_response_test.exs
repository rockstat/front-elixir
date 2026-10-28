defmodule RockstatFront.BandResponseTest do
  use ExUnit.Case, async: true

  alias RockstatFront.BandResponse

  test "native_json содержит только осмысленные для типа поля, без headers" do
    redirect = BandResponse.redirect("https://x.io", headers: [["H", "v"]])

    assert Jason.decode!(BandResponse.native_json(redirect)) == %{
             "type__" => "redirect",
             "statusCode" => 302,
             "location" => "https://x.io"
           }

    error = BandResponse.error(status: 400)
    decoded = Jason.decode!(BandResponse.native_json(error))
    assert decoded["type__"] == "error"
    assert decoded["errorMessage"] == "Bad Request"
  end

  test "from_map восстанавливает ответ удалённого сервиса" do
    resp = BandResponse.from_map(%{"type__" => "redirect", "location" => "https://y.io"})
    assert resp.type__ == "redirect"
    assert resp.location == "https://y.io"
    # дефолты, как в rock-me-ts handlersGateway
    assert resp.statusCode == 200
    assert resp.headers == []
  end
end
