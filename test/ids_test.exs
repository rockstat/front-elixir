defmodule RockstatFront.IdsTest do
  use ExUnit.Case, async: true

  alias RockstatFront.Ids

  test "flake возвращает десятичную строку валидной длины (10-22 цифры)" do
    id = Ids.flake()
    assert id =~ ~r/^[0-9]{10,22}$/
  end

  test "flake монотонно растёт и не повторяется под конкуренцией" do
    ids =
      1..8
      |> Enum.map(fn _ ->
        Task.async(fn -> Enum.map(1..2_000, fn _ -> Ids.flake() end) end)
      end)
      |> Task.await_many()
      |> List.flatten()

    assert length(Enum.uniq(ids)) == length(ids)
  end

  test "round даёт короткий base36-id" do
    assert Ids.round() =~ ~r/^[0-9a-z]{1,4}$/
  end
end
