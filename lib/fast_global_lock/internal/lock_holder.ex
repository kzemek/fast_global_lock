defmodule FastGlobalLock.Internal.LockHolder do
  @moduledoc false
  use GenServer

  alias __MODULE__, as: State
  alias FastGlobalLock.Internal.Utils, as: Utils

  @typep global_owner :: {pid(), reference()}

  @enforce_keys [:resource, :nodes]
  defstruct [
    :resource,
    :nodes,
    parent: nil,
    notified_owner: nil,
    locked?: false,
    times: 0,
    peers: []
  ]

  @typep state :: %State{
           resource: term(),
           nodes: [node()],
           parent: GenServer.from() | nil,
           notified_owner: global_owner() | nil,
           locked?: boolean(),
           times: non_neg_integer(),
           peers: [pid()]
         }

  @impl GenServer
  def init({resource, nodes}),
    do: {:ok, %State{resource: resource, nodes: nodes}}

  @impl GenServer
  def handle_call({:set_lock, timeout}, parent, %State{locked?: false} = state) do
    if timeout != :infinity, do: :erlang.send_after(timeout, self(), :lock_timeout)
    try_lock(%{state | parent: parent})
  end

  def handle_call(:del_lock, from, %State{locked?: true} = state) do
    del_lock(state)
    GenServer.reply(from, true)
    {:stop, :normal, %{state | locked?: false}}
  end

  @impl GenServer
  def handle_cast({:awaiting_lock, peer}, %State{} = state),
    do: {:noreply, %{state | peers: [peer | state.peers]}}

  def handle_cast(:released_lock, %State{} = state),
    do: try_lock(state)

  @impl GenServer
  def handle_info(:lock_timeout, %State{locked?: false} = state) do
    GenServer.reply(state.parent, false)
    {:stop, :normal, state}
  end

  def handle_info(:lock_timeout, %State{locked?: true} = state),
    do: {:noreply, state}

  def handle_info(:timeout, %State{} = state),
    do: try_lock(state)

  @impl GenServer
  def terminate(_reason, %State{} = state),
    do: del_lock(state)

  @spec try_lock(state()) :: {:noreply, state()} | {:noreply, state(), timeout()}
  defp try_lock(%State{locked?: true} = state),
    do: {:noreply, state}

  defp try_lock(%State{parent: {parent_pid, _tag}} = state) do
    if :global.set_lock({state.resource, parent_pid}, state.nodes, 0) do
      GenServer.reply(state.parent, true)
      Process.flag(:trap_exit, true)
      {:noreply, %{state | locked?: true}}
    else
      notified_owner = notify_lock_owner(state.resource, state.nodes, state.notified_owner)
      new_state = %{state | notified_owner: notified_owner, times: state.times + 1}

      if is_nil(notified_owner),
        do: try_lock(new_state),
        else: {:noreply, new_state, random_sleep(state.times)}
    end
  end

  @spec del_lock(state()) :: :ok
  defp del_lock(%State{locked?: false}),
    do: :ok

  defp del_lock(%State{parent: {parent_pid, _tag}} = state) do
    :global.del_lock({state.resource, parent_pid}, state.nodes)
    Process.flag(:trap_exit, false)

    if peer = Enum.find(Enum.reverse(state.peers), &(node(&1) != :nonode@nohost)),
      do: GenServer.cast(peer, :released_lock)

    :ok
  end

  @spec notify_lock_owner(term(), [node()], global_owner() | nil) :: global_owner() | nil
  defp notify_lock_owner(resource, nodes, previously_notified_owner) do
    case Utils.whereis_lock(resource, nodes) do
      nil -> nil
      {_on_behalf_of, ^previously_notified_owner} -> previously_notified_owner
      {_on_behalf_of, new_owner} -> do_notify_lock_owner(resource, nodes, new_owner)
    end
  end

  defp do_notify_lock_owner(resource, nodes, {owner_pid, _lock_ref} = owner) do
    GenServer.cast(owner_pid, {:awaiting_lock, self()})

    # the owner may have changed from under us while we were notifying it
    case Utils.whereis_lock(resource, nodes) do
      nil -> nil
      {_on_behalf_of, ^owner} -> owner
      {_on_behalf_of, new_owner} -> do_notify_lock_owner(resource, nodes, new_owner)
    end
  end

  # Same algorithm as :global, but we can be woken up by messages
  defp random_sleep(times) do
    if rem(times, 10) == 0, do: :rand.seed(:exsplus)
    # First time 1/4 seconds, then doubling each time up to 8 seconds max.
    tmax = if times > 5, do: 8000, else: div(Bitwise.bsl(1, times) * 1000, 8)
    :rand.uniform(tmax)
  end
end
