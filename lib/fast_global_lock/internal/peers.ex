defmodule FastGlobalLock.Internal.Peers do
  @moduledoc false

  @always_maintained_peers_cnt 5
  @max_tombstones_cnt 100
  @initial_gc_target 64
  @erpc_timeout to_timeout(millisecond: 100)

  @enforce_keys [:size, :front, :rest, :known, :gc_target]
  defstruct [:size, :front, :rest, :known, :gc_target]

  @type t :: %__MODULE__{
          size: non_neg_integer(),
          front: [pid()],
          rest: :queue.queue(pid()),
          known: MapSet.t(pid()),
          gc_target: pos_integer()
        }

  def new do
    %__MODULE__{
      size: 0,
      front: [],
      rest: :queue.new(),
      known: MapSet.new(),
      gc_target: @initial_gc_target
    }
  end

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

  def remove(%__MODULE__{} = peers, peer),
    do: peers |> remove_nomaintain(peer) |> maintain()

  defp remove_nomaintain(%__MODULE__{} = peers, peer) do
    cond do
      not contains?(peers, peer) ->
        peers

      peer in peers.front ->
        %{
          peers
          | size: peers.size - 1,
            front: peers.front -- [peer],
            known: MapSet.delete(peers.known, peer)
        }

      true ->
        %{peers | known: MapSet.delete(peers.known, peer)}
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

  def monitored(%__MODULE__{} = peers),
    do: peers.front

  def maintain(%__MODULE__{} = peers) do
    cond do
      length(peers.front) < @always_maintained_peers_cnt and not :queue.is_empty(peers.rest) ->
        {{:value, peer}, rest} = :queue.out(peers.rest)

        {front, size} =
          if peer in peers.known do
            Process.monitor(peer)
            {peers.front ++ [peer], peers.size}
          else
            {peers.front, peers.size - 1}
          end

        maintain(%{peers | size: size, front: front, rest: rest})

      MapSet.size(peers.known) > peers.gc_target ->
        cleaned_up_peers =
          peers.known
          |> collect_dead_peers()
          |> Enum.reduce(peers, &remove_nomaintain(&2, &1))

        gc_target =
          if MapSet.size(cleaned_up_peers.known) > div(peers.gc_target, 2),
            do: peers.gc_target * 2,
            else: peers.gc_target

        maintain(%{cleaned_up_peers | gc_target: gc_target})

      peers.size - MapSet.size(peers.known) > @max_tombstones_cnt ->
        rest = :queue.filter(&(&1 in peers.known), peers.rest)
        size = MapSet.size(peers.known)
        maintain(%{peers | size: size, rest: rest})

      true ->
        peers
    end
  end

  defp collect_dead_peers(peers) do
    peers_by_node = Enum.group_by(peers, &node/1)

    peers_by_node
    |> Enum.reduce(:erpc.reqids_new(), fn {node, peers}, reqids ->
      :erpc.send_request(node, fn -> Enum.reject(peers, &Process.alive?/1) end, node, reqids)
    end)
    |> receive_dead_peers(peers_by_node)
  end

  defp receive_dead_peers(reqids, peers_by_node, acc \\ []) do
    case :erpc.receive_response(reqids, @erpc_timeout, true) do
      :no_request -> acc
      {dead_peers, _node, reqids} -> receive_dead_peers(reqids, peers_by_node, dead_peers ++ acc)
    end
  catch
    :error, {_reason, node, reqids} ->
      dead_peers = Map.fetch!(peers_by_node, node)
      receive_dead_peers(reqids, peers_by_node, dead_peers ++ acc)
  end
end
