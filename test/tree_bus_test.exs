defmodule RockstatFront.TreeBusTest do
  use ExUnit.Case, async: true

  alias RockstatFront.TreeBus

  test "подписка на префикс ловит всё поддерево" do
    tree = TreeBus.new() |> TreeBus.subscribe("in.gen.track", :h)

    assert {:h, "in.gen.track"} = TreeBus.resolve(tree, "in.gen.track.pageview")
    assert {:h, "in.gen.track"} = TreeBus.resolve(tree, "in.gen.track")
    assert TreeBus.resolve(tree, "in.gen.pixel.visit") == nil
  end

  test "'*' подписывает на корень (получает всё)" do
    tree = TreeBus.new() |> TreeBus.subscribe("*", :default)

    assert {:default, ""} = TreeBus.resolve(tree, "in.gen.anything.at.all")
  end

  test "resolve берёт самый специфичный, collect — всех по пути" do
    tree =
      TreeBus.new()
      |> TreeBus.subscribe("*", :default)
      |> TreeBus.subscribe("in.gen", :mid)
      |> TreeBus.subscribe("in.gen.track", :track)

    assert {:track, "in.gen.track"} = TreeBus.resolve(tree, "in.gen.track.event")

    handlers = tree |> TreeBus.collect("in.gen.track.event") |> Enum.map(&elem(&1, 0))
    assert handlers == [:default, :mid, :track]
  end

  test "unsubscribe убирает подписчика" do
    tree =
      TreeBus.new()
      |> TreeBus.subscribe("in.gen.x", :h)
      |> TreeBus.unsubscribe("in.gen.x", :h)

    assert TreeBus.resolve(tree, "in.gen.x.y") == nil
  end
end
