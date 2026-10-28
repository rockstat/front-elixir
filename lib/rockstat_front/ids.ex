defmodule RockstatFront.Ids do
  @moduledoc """
  ID generation, wire-compatible with rock-me-ts `TheIds`:

  * `flake/0` — 64-bit snowflake in flake-idgen layout
    (42 bits unix-ms | 5 bits datacenter | 5 bits worker | 12 bits counter),
    returned as unsigned decimal string;
  * `round/0` — rpc request id: round counter rendered in base36.
  """

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def flake, do: GenServer.call(__MODULE__, :flake)
  def round, do: GenServer.call(__MODULE__, :round)

  # размер кольца rpc-счётчика, как в rock-me-ts IdGenRoundCounter
  @round_size 99_999

  # datacenter/worker берутся из env (DATACENTER_ID/WORKER_ID) и усекаются
  # до 5 бит каждый; round стартует со случайной позиции, чтобы id запросов
  # разных инстансов не совпадали после рестарта
  @impl true
  def init(_opts) do
    datacenter = env_int("DATACENTER_ID", 1)
    worker = env_int("WORKER_ID", 1)

    {:ok,
     %{
       dc: Bitwise.band(datacenter, 0x1F),
       worker: Bitwise.band(worker, 0x1F),
       last_ts: 0,
       seq: 0,
       round: :rand.uniform(@round_size)
     }}
  end

  # Генерация snowflake: монотонное время + счётчик внутри миллисекунды.
  # GenServer гарантирует сериализацию — коллизии исключены.
  @impl true
  def handle_call(:flake, _from, state) do
    now = System.system_time(:millisecond)

    {ts, seq} =
      cond do
        # новая миллисекунда — счётчик с нуля
        now > state.last_ts -> {now, 0}
        # та же миллисекунда — инкремент (до 4096 id/мс)
        state.seq < 0xFFF -> {state.last_ts, state.seq + 1}
        # счётчик исчерпан внутри одной мс — виртуально шагаем в следующую
        true -> {state.last_ts + 1, 0}
      end

    id =
      ts
      |> Bitwise.bsl(22)
      |> Bitwise.bor(Bitwise.bsl(state.dc, 17))
      |> Bitwise.bor(Bitwise.bsl(state.worker, 12))
      |> Bitwise.bor(seq)
      |> Bitwise.band(0xFFFFFFFFFFFFFFFF)

    {:reply, Integer.to_string(id), %{state | last_ts: ts, seq: seq}}
  end

  def handle_call(:round, _from, state) do
    num = if state.round >= @round_size, do: 1, else: state.round + 1
    {:reply, String.downcase(Integer.to_string(num, 36)), %{state | round: num}}
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
