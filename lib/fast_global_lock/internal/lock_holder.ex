defmodule FastGlobalLock.Internal.LockHolder do
  @moduledoc false
  use GenServer

  require Logger

  alias __MODULE__, as: State
  alias FastGlobalLock.Internal.Peers

  @poll_interval to_timeout(second: 1)
  @poll_jitter to_timeout(millisecond: 200)
  @poll_min_interval to_timeout(millisecond: 10)
  @handover_timeout to_timeout(millisecond: 100)

  @enforce_keys [:resource, :nodes]
  defstruct [
    :resource,
    :nodes,
    parent: nil,
    notified_owner: nil,
    peers: Peers.new(),
    has_lock?: false,
    had_lock?: false
  ]

  @typep state :: %State{
           resource: term(),
           nodes: [node()],
           parent: GenServer.from() | nil,
           notified_owner: pid() | nil,
           peers: Peers.t(),
           had_lock?: boolean(),
           has_lock?: boolean()
         }

  @impl GenServer
  def init({resource, nodes, parent_pid, 0 = _timeout}) do
    case try_lock_once(%State{resource: resource, nodes: nodes, parent: {parent_pid, nil}}) do
      %State{has_lock?: true} = locked_state -> {:ok, locked_state}
      _ -> :ignore
    end
  end

  def init({resource, nodes, _parent_pid, timeout}) do
    if timeout != :infinity, do: :erlang.send_after(timeout, self(), :lock_timeout)
    {:ok, %State{resource: resource, nodes: nodes}}
  end

  @impl GenServer
  def handle_call(:set_lock, _parent, %State{has_lock?: true} = state) do
    Logger.warning("set_lock called on locked state")
    {:reply, true, state}
  end

  def handle_call(:set_lock, parent, %State{} = state),
    do: {:noreply, %{state | parent: parent}, 0}

  def handle_call(:del_lock, _from, %State{has_lock?: true} = state) do
    new_state = del_global_lock(state)
    {:reply, :ok, new_state, {:continue, :stop}}
  end

  def handle_call(:del_lock, _from, %State{} = state) do
    Logger.error("del_lock called on unlocked state")
    {:stop, :del_lock_on_unlocked_state, state}
  end

  def handle_call({:peer_released_lock, peers}, _from, %State{} = state) do
    case try_lock(state) do
      %State{has_lock?: true} = locked_state ->
        {:reply, true, locked_state, {:continue, {:take_over_peers, peers}}}

      %State{} = state ->
        {:reply, false, state, timeout(state)}
    end
  end

  def handle_call({:peer_awaiting_lock, peer}, _from, %State{had_lock?: true} = state),
    do: {:reply, true, %{state | peers: Peers.add(state.peers, peer)}}

  def handle_call({:peer_awaiting_lock, _peer}, _from, %State{} = state),
    do: {:reply, false, state, timeout(state)}

  @impl GenServer
  def handle_continue({:take_over_peers, peers}, %State{} = state) do
    # There's an edge case where this holder took a lock before being notified by the previous
    # owner. In that case, we might have some peers already, but there shouldn't be many.

    merged_peers =
      state.peers
      |> Peers.to_list()
      |> Enum.reduce(peers, &Peers.add(&2, &1))
      |> Peers.maintain()

    # We can leave any previous monitors in place, they don't break the logic.
    for peer <- Peers.monitored(merged_peers),
        peer not in Peers.monitored(state.peers),
        do: Process.monitor(peer)

    {:noreply, %{state | peers: merged_peers}}
  end

  def handle_continue(:stop, %State{} = state),
    do: {:stop, :normal, state}

  @impl GenServer
  def handle_info(:lock_timeout, %State{has_lock?: true} = state),
    do: {:noreply, state}

  def handle_info(:lock_timeout, %State{} = state) do
    GenServer.reply(state.parent, false)
    {:stop, :normal, state}
  end

  def handle_info(:timeout, %State{} = state) do
    case try_lock(state) do
      %State{has_lock?: true} = locked_state -> {:noreply, locked_state}
      %State{} = state -> {:noreply, state, timeout(state)}
    end
  end

  def handle_info({:DOWN, _, :process, peer, _reason}, %State{has_lock?: true} = state) do
    peers = Peers.remove(state.peers, peer)
    {:noreply, %{state | peers: peers}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %State{} = state),
    do: {:noreply, state, 0}

  def handle_info({ref, _late_genserver_reply}, %State{} = state) when is_reference(ref),
    do: if(state.has_lock?, do: {:noreply, state}, else: {:noreply, state, 0})

  @impl GenServer
  def terminate(_reason, %State{} = state) do
    if state.has_lock?, do: del_global_lock(state)
    if state.had_lock?, do: release_lock_to_first_peer(state.peers)
    :ok
  end

  @spec try_lock(state()) :: state()
  defp try_lock(%State{has_lock?: true} = state),
    do: state

  defp try_lock(%State{} = state) do
    case try_lock_once(state) do
      %State{has_lock?: true} = locked_state ->
        GenServer.reply(state.parent, true)
        locked_state

      %State{} = state ->
        {lock_found?, state} = notify_lock_owner(state)
        if lock_found?, do: state, else: try_lock(state)
    end
  end

  defp try_lock_once(%State{parent: {parent_pid, _tag}} = state) do
    if :global.set_lock({state.resource, parent_pid}, state.nodes, 0) do
      Process.flag(:trap_exit, true)
      %{state | has_lock?: true, had_lock?: true}
    else
      state
    end
  end

  @spec del_global_lock(state()) :: state()
  defp del_global_lock(%State{parent: {parent_pid, _tag}, has_lock?: true} = state) do
    :global.del_lock({state.resource, parent_pid}, state.nodes)
    %{state | has_lock?: false}
  end

  defp release_lock_to_first_peer(%Peers{} = peers) do
    case Peers.pop_delaymaintain(peers) do
      :empty ->
        :ok

      {peer, next_peers} ->
        try do
          if not GenServer.call(peer, {:peer_released_lock, next_peers}, @handover_timeout) do
            for peer <- Peers.as_unordered_enumerable(next_peers),
                not Peers.contains?(peers, peer),
                do: send(peer, :timeout)
          end
        catch
          :exit, _ -> release_lock_to_first_peer(next_peers)
        end
    end
  end

  @spec notify_lock_owner(state()) :: {boolean(), state()}
  defp notify_lock_owner(%State{} = state) do
    previously_notified_owner = state.notified_owner

    case whereis_lock(state.resource, state.nodes) do
      nil ->
        # That we didn't find the lock doesn't mean it's not there (we might have checked a wrong
        # node), so don't change `notified_owner` in this state
        {false, state}

      ^previously_notified_owner ->
        {true, state}

      new_owner ->
        try do
          if GenServer.call(new_owner, {:peer_awaiting_lock, self()}, @handover_timeout),
            do: {true, %{state | notified_owner: new_owner}},
            else: notify_lock_owner(state)
        catch
          :exit, _ -> notify_lock_owner(state)
        end
    end
  end

  @spec timeout(state()) :: non_neg_integer()
  defp timeout(_state),
    do: max(@poll_interval + :rand.uniform(@poll_jitter) * 2 - @poll_jitter, @poll_min_interval)

  @spec whereis_lock(any(), [node()]) :: pid() | nil
  defp whereis_lock(resource, nodes) do
    node = Enum.random(nodes)

    case :erpc.call(node, :ets, :lookup, [:global_locks, resource]) do
      # while the lock is unlocked, the `:global_locks` entry can contain a process that tried and
      # failed to acquire it
      [{_resource, _on_behalf_of, [{owner, _}]}] when owner != self() -> owner
      _ -> nil
    end
  catch
    _, _ -> nil
  end
end
