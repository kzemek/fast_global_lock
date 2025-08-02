defmodule FastGlobalLock.Internal.Peers do
  @moduledoc false

  @always_maintained_peers_cnt 5
  @max_tombstones_cnt 100

  @enforce_keys [:size, :front, :rest, :known]
  defstruct [:size, :front, :rest, :known]

  @type t :: %__MODULE__{
          size: non_neg_integer(),
          front: [pid()],
          rest: :queue.queue(pid()),
          known: MapSet.t(pid())
        }

  def new,
    do: %__MODULE__{size: 0, front: [], rest: :queue.new(), known: MapSet.new()}

  def contains?(%__MODULE__{} = peers, peer),
    do: MapSet.member?(peers.known, peer)

  def add(%__MODULE__{} = peers, peer) do
    if contains?(peers, peer) do
      peers
    else
      maintain(%{
        peers
        | size: peers.size + 1,
          rest: :queue.in(peer, peers.rest),
          known: MapSet.put(peers.known, peer)
      })
    end
  end

  def remove(%__MODULE__{} = peers, peer) do
    cond do
      not contains?(peers, peer) ->
        peers

      peer in peers.front ->
        maintain(%{
          peers
          | size: peers.size - 1,
            front: peers.front -- [peer],
            known: MapSet.delete(peers.known, peer)
        })

      true ->
        maintain(%{peers | known: MapSet.delete(peers.known, peer)})
    end
  end

  def as_unordered_enumerable(%__MODULE__{} = peers),
    do: peers.known

  def to_list(%__MODULE__{} = peers) do
    rest = :queue.filter(&(&1 in peers.known), peers.rest)
    peers.front ++ :queue.to_list(rest)
  end

  def pop_smallest_delay_maintain(%__MODULE__{front: [peer | front]} = peers) do
    size = peers.size - 1
    known = MapSet.delete(peers.known, peer)
    {peer, %{peers | size: size, front: front, known: known}}
  end

  def pop_smallest_delay_maintain(%__MODULE__{} = peers) do
    if MapSet.size(peers.known) == 0,
      do: :empty,
      else: peers |> maintain() |> pop_smallest_delay_maintain()
  end

  def maintain(%__MODULE__{} = peers) do
    cond do
      length(peers.front) < @always_maintained_peers_cnt and not :queue.is_empty(peers.rest) ->
        {{:value, peer}, rest} = :queue.out(peers.rest)

        {front, size} =
          if peer in peers.known,
            do: {peers.front ++ [peer], peers.size},
            else: {peers.front, peers.size - 1}

        maintain(%{peers | size: size, front: front, rest: rest})

      peers.size - MapSet.size(peers.known) > @max_tombstones_cnt ->
        rest = :queue.filter(&(&1 in peers.known), peers.rest)
        size = MapSet.size(peers.known)
        %{peers | size: size, rest: rest}

      true ->
        peers
    end
  end
end
