defmodule FastGlobalLock do
  alias FastGlobalLock.Internal.LockHolder
  alias FastGlobalLock.Internal.Utils

  @spec set_lock(key :: term(), [node()] | nil, timeout()) :: boolean()
  def set_lock(key, nodes \\ nil, timeout \\ :infinity) do
    nodes = nodes || Node.list([:this, :visible])

    case Utils.whereis_lock(key, nodes) do
      {on_behalf_of, {owner_pid, _lock_ref}} when on_behalf_of == self() ->
        GenServer.cast(owner_pid, :nest_lock)
        true

      _ ->
        {:ok, lock_holder} = GenServer.start_link(LockHolder, {key, nodes})
        GenServer.call(lock_holder, {:set_lock, timeout}, :infinity)
    end
  end

  @spec del_lock(key :: term(), [node()] | nil) :: boolean()
  def del_lock(key, nodes \\ nil) do
    nodes = nodes || Node.list([:this, :visible])

    case Utils.whereis_lock(key, nodes) do
      {on_behalf_of, {owner_pid, _lock_ref}} when on_behalf_of == self() ->
        GenServer.call(owner_pid, :del_lock, :infinity)

      _ ->
        true
    end
  end

  @spec trans(key :: term(), fun :: (-> any()), [node()] | nil, timeout()) :: any() | :aborted
  def trans(key, fun, nodes \\ nil, timeout \\ :infinity) do
    nodes = nodes || Node.list([:this, :visible])

    if set_lock(key, nodes, timeout) do
      try do
        fun.()
      after
        del_lock(key, nodes)
      end
    else
      :aborted
    end
  end
end
