defmodule RockstatFront.TreeBus do
  @moduledoc """
  Hierarchical routing tree, port of `src/bus/tree.ts` as a pure data structure.

  Keys are dot-paths (`in.gen.track.event`); a handler subscribed at a prefix
  node receives everything below it, `*` subscribes at the root. Handlers are
  arbitrary terms — the Dispatcher stores `{:internal, module}` / `:rpc_gateway`
  tags and interprets them at call time.
  """

  # Узел дерева: подписчики этого уровня + дочерние узлы по сегментам ключа.
  # Пример: подписка на "in.gen.track" живёт в root -> in -> gen -> track.
  defstruct handlers: [], children: %{}

  @type t :: %__MODULE__{}

  def new, do: %__MODULE__{}

  @doc "Подписывает handler на ключ (точечный путь или '*' для корня)."
  def subscribe(tree, key, handler) do
    put_at(tree, path(key), handler)
  end

  def unsubscribe(tree, key, handler) do
    drop_at(tree, path(key), handler)
  end

  @doc "Replace subscriptions: `handler` stays subscribed exactly to `keys`."
  def replace(tree, keys, handler, current_keys) do
    tree =
      Enum.reduce(current_keys -- keys, tree, fn k, t -> unsubscribe(t, k, handler) end)

    Enum.reduce(keys -- current_keys, tree, fn k, t -> subscribe(t, k, handler) end)
  end

  @doc """
  Все подписчики на пути от корня до самого глубокого совпавшего узла
  (используется для энричеров — срабатывают все). Возвращает пары
  {handler, совпавший_префикс}.
  """
  def collect(tree, key) do
    walk(tree, String.split(key, "."), [], [])
  end

  @doc """
  Самый специфичный подписчик для ключа + совпавший префикс (используется
  для трансформеров и обработчиков — срабатывает один). Эквивалент
  tree.ts `handler()`: вызывается последний собранный по пути handler.
  """
  def resolve(tree, key) do
    case collect(tree, key) do
      [] -> nil
      found -> List.last(found)
    end
  end

  # — внутренности —

  # '*' означает подписку на корень (получает вообще всё)
  defp path("*"), do: []
  defp path(key), do: String.split(key, ".")

  defp put_at(node, [], handler), do: %{node | handlers: node.handlers ++ [handler]}

  defp put_at(node, [name | rest], handler) do
    child = Map.get(node.children, name, new())
    %{node | children: Map.put(node.children, name, put_at(child, rest, handler))}
  end

  defp drop_at(node, [], handler),
    do: %{node | handlers: Enum.reject(node.handlers, &(&1 == handler))}

  defp drop_at(node, [name | rest], handler) do
    case Map.get(node.children, name) do
      nil -> node
      child -> %{node | children: Map.put(node.children, name, drop_at(child, rest, handler))}
    end
  end

  # Спуск по сегментам ключа со сбором {handler, совпавший_путь};
  # остановка на первом отсутствующем дочернем узле
  # (зеркалит обход в tree.ts `handler`/`publish`).
  defp walk(node, parts, matched, acc) do
    acc = acc ++ Enum.map(node.handlers, &{&1, Enum.join(Enum.reverse(matched), ".")})

    case parts do
      [] ->
        acc

      [name | rest] ->
        case Map.get(node.children, name) do
          nil -> acc
          child -> walk(child, rest, [name | matched], acc)
        end
    end
  end
end
