defmodule FastGlobalLock.Internal.LockHolder do
  @moduledoc false
  use GenServer

  require Logger

  alias __MODULE__, as: State
  alias FastGlobalLock.Internal.Utils, as: Utils

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
    lock_count: 0,
    peers: %{},
    peer_generation: 0,
    had_lock?: false
  ]

  @typep state :: %State{
           resource: term(),
           nodes: [node()],
           parent: GenServer.from() | nil,
           notified_owner: Utils.global_owner() | nil,
           lock_count: non_neg_integer(),
           peers: %{optional(pid()) => non_neg_integer()},
           peer_generation: non_neg_integer(),
           had_lock?: boolean()
         }

  defguardp has_lock(state) when state.lock_count > 0

  @impl GenServer
  def init({resource, nodes}),
    do: {:ok, %State{resource: resource, nodes: nodes}}

  @impl GenServer
  def handle_call({:set_lock, _timeout}, _parent, %State{} = state) when has_lock(state) do
    Logger.warning("FastGlobalLock: set_lock called on locked state")
    {:reply, true, %{state | lock_count: state.lock_count + 1}}
  end

  def handle_call({:set_lock, timeout}, parent, %State{} = state) do
    if timeout != :infinity, do: :erlang.send_after(timeout, self(), :lock_timeout)
    noreply_try_lock(%{state | parent: parent})
  end

  def handle_call(:del_lock, _from, %State{lock_count: 1} = state) do
    new_state = del_global_lock(state)
    {:reply, true, new_state, {:continue, :stop}}
  end

  def handle_call(:del_lock, _from, %State{} = state) when has_lock(state),
    do: {:reply, true, %{state | lock_count: state.lock_count - 1}}

  def handle_call(:del_lock, _from, %State{} = state) do
    Logger.error("FastGlobalLock: del_lock called on unlocked state")
    {:stop, :del_lock_on_unlocked_state, state}
  end

  def handle_call({:peer_released_lock, peers}, _from, %State{} = state) do
    new_state = try_lock(state)

    next_step =
      if has_lock(new_state),
        do: {:continue, {:take_over_peers, peers}},
        else: timeout(new_state)

    {:reply, :ok, new_state, next_step}
  end

  @impl GenServer
  def handle_continue({:take_over_peers, peers}, %State{} = state) do
    # There's an edge case where this process aquired the lock before receiving
    # `:peer_released_lock` message. In this case, we can't tell the ordering between the current
    # peers and the received peers, so we just merge them and allow duplicate generations
    peers = Map.merge(peers, state.peers)

    peer_generation = Enum.max([-1 | Map.values(peers)]) + 1
    Enum.each(Map.keys(peers), &Process.monitor/1)
    {:noreply, %{state | peers: peers, peer_generation: peer_generation}}
  end

  def handle_continue(:stop, %State{} = state),
    do: {:stop, :normal, state}

  @impl GenServer
  def handle_cast(:nest_lock, %State{} = state) when has_lock(state),
    do: {:noreply, %{state | lock_count: state.lock_count + 1}}

  def handle_cast(:nest_lock, %State{} = state) do
    Logger.error("FastGlobalLock: nest_lock called on unlocked state")
    {:stop, :nest_lock_on_unlocked_state, state}
  end

  def handle_cast({:peer_awaiting_lock, peer}, %State{} = state)
      when is_map_key(state.peers, peer),
      do: {:noreply, state}

  def handle_cast({:peer_awaiting_lock, peer}, %State{} = state) do
    Process.monitor(peer)
    peer_num = state.peer_generation
    peers = Map.put(state.peers, peer, peer_num)
    {:noreply, %{state | peers: peers, peer_generation: peer_num + 1}}
  end

  @impl GenServer
  def handle_info(:lock_timeout, %State{} = state) when has_lock(state),
    do: {:noreply, state}

  def handle_info(:lock_timeout, %State{} = state) do
    GenServer.reply(state.parent, false)
    {:stop, :normal, state}
  end

  def handle_info(:timeout, %State{} = state),
    do: noreply_try_lock(state)

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %State{} = state) when has_lock(state),
    do: {:noreply, %{state | peers: Map.delete(state.peers, pid)}}

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %State{} = state),
    do: noreply_try_lock(state)

  def handle_info({ref, _late_genserver_reply}, %State{} = state) when is_reference(ref),
    do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %State{} = state) do
    if has_lock(state), do: del_global_lock(state)
    if state.had_lock?, do: release_lock_to_first_peer(state.peers)
    :ok
  end

  defp noreply_try_lock(state) do
    new_state = try_lock(state)

    if has_lock(new_state),
      do: {:noreply, new_state},
      else: {:noreply, new_state, timeout(new_state)}
  end

  @spec try_lock(state()) :: state()
  defp try_lock(%State{} = state) when has_lock(state),
    do: state

  defp try_lock(%State{parent: {parent_pid, _tag}} = state) do
    if :global.set_lock({state.resource, parent_pid}, state.nodes, 0) do
      Process.flag(:trap_exit, true)
      GenServer.reply(state.parent, true)
      %{state | lock_count: state.lock_count + 1, had_lock?: true}
    else
      notified_owner = notify_lock_owner(state.resource, state.nodes, state.notified_owner)
      new_state = %{state | notified_owner: notified_owner}

      if is_nil(notified_owner) do
        try_lock(new_state)
      else
        if notified_owner != state.notified_owner, do: monitor_owner(notified_owner)
        new_state
      end
    end
  end

  defp monitor_owner({pid, _lock_ref}),
    do: Process.monitor(pid)

  @spec del_global_lock(state()) :: state()
  defp del_global_lock(%State{parent: {parent_pid, _tag}} = state) when has_lock(state) do
    :global.del_lock({state.resource, parent_pid}, state.nodes)
    %{state | lock_count: 0}
  end

  defp release_lock_to_first_peer(peers) when is_map(peers),
    do: peers |> Enum.sort_by(fn {_peer, num} -> num end) |> release_lock_to_first_peer()

  defp release_lock_to_first_peer([]),
    do: :ok

  defp release_lock_to_first_peer([{first_peer, _peer_num} | peers]) do
    GenServer.call(first_peer, {:peer_released_lock, Map.new(peers)}, @handover_timeout)
  catch
    :exit, _ -> release_lock_to_first_peer(peers)
  end

  @spec notify_lock_owner(term(), [node()], Utils.global_owner() | nil) ::
          Utils.global_owner() | nil
  defp notify_lock_owner(resource, nodes, previously_notified_owner) do
    case Utils.whereis_lock(resource, nodes) do
      nil -> nil
      {_on_behalf_of, ^previously_notified_owner} -> previously_notified_owner
      {_on_behalf_of, new_owner} -> do_notify_lock_owner(resource, nodes, new_owner)
    end
  end

  defp do_notify_lock_owner(resource, nodes, {owner_pid, _lock_ref} = owner) do
    GenServer.cast(owner_pid, {:peer_awaiting_lock, self()})

    # the owner may have changed from under us while we were notifying it
    case Utils.whereis_lock(resource, nodes) do
      nil -> nil
      {_on_behalf_of, ^owner} -> owner
      {_on_behalf_of, new_owner} -> do_notify_lock_owner(resource, nodes, new_owner)
    end
  end

  @spec timeout(state()) :: non_neg_integer()
  defp timeout(_state),
    do: max(@poll_interval + :rand.uniform(@poll_jitter) * 2 - @poll_jitter, @poll_min_interval)
end
