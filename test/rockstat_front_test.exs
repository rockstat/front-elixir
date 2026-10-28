defmodule RockstatFrontTest do
  use ExUnit.Case
  doctest RockstatFront

  test "greets the world" do
    assert RockstatFront.hello() == :world
  end
end
