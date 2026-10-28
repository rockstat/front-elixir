defmodule RockstatFront.Ids do
  @moduledoc """
  Генерация идентификаторов без процесса-посредника — на `:atomics`,
  чтобы flake() из параллельных запросов не сериализовался через GenServer
  (батч на N событий просит N идентификаторов).

  * `flake/0` — 64-битный snowflake в раскладке flake-idgen
    (42 бита unix-ms | 5 бит datacenter | 5 бит worker | 12 бит счётчик),
    строкой в десятичной записи;
  * `round/0` — id RPC-запроса: кольцевой счётчик в base36.
  """

  import Bitwise

  @key {__MODULE__, :state}
  @round_size 99_999

  # индексы в atomics-массиве
  @ix_tseq 1
  @ix_round 2

  @doc "Вызывается один раз при старте приложения (до запуска детей)."
  def setup! do
    datacenter = env_int("DATACENTER_ID", 1) &&& 0x1F
    worker = env_int("WORKER_ID", 1) &&& 0x1F

    ref = :atomics.new(2, signed: false)

    # составное значение ts<<12|seq — счётчик и время меняются одним CAS-ом
    :atomics.put(ref, @ix_tseq, System.system_time(:millisecond) <<< 12)

    # round стартует со случайной позиции, чтобы id запросов разных
    # инстансов/рестартов не совпадали
    :atomics.put(ref, @ix_round, :rand.uniform(@round_size))

    :persistent_term.put(@key, {ref, datacenter, worker})
  end

  @doc "Уникальный snowflake-id (строка из цифр)."
  def flake do
    {ref, dc, worker} = :persistent_term.get(@key)
    tseq = next_tseq(ref)

    ts = tseq >>> 12
    seq = tseq &&& 0xFFF

    id =
      ts
      |> bsl(22)
      |> bor(bsl(dc, 17))
      |> bor(bsl(worker, 12))
      |> bor(seq)
      |> band(0xFFFFFFFFFFFFFFFF)

    Integer.to_string(id)
  end

  @doc "Короткий id RPC-запроса (base36)."
  def round do
    {ref, _dc, _worker} = :persistent_term.get(@key)
    n = :atomics.add_get(ref, @ix_round, 1)
    (rem(n, @round_size) + 1) |> Integer.to_string(36) |> String.downcase()
  end

  # Lock-free инкремент составного ts<<12|seq через CAS-цикл:
  # берём максимум из "текущее время, счётчик 0" и "предыдущее значение + 1".
  # Переполнение 12-битного счётчика естественно переносится в биты времени —
  # это и есть семантика "шагнуть в следующую миллисекунду" при >4096 id/мс.
  defp next_tseq(ref) do
    cur = :atomics.get(ref, @ix_tseq)
    candidate = max(System.system_time(:millisecond) <<< 12, cur + 1)

    case :atomics.compare_exchange(ref, @ix_tseq, cur, candidate) do
      :ok -> candidate
      # другой процесс успел раньше — повторяем с актуальным значением
      _actual -> next_tseq(ref)
    end
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      v -> String.to_integer(v)
    end
  rescue
    _ -> default
  end
end
