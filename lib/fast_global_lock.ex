defmodule FastGlobalLock do
  alias FastGlobalLock.Internal.LockHolder
  alias FastGlobalLock.Internal.Utils

  @spec set_lock(key :: term(), [node()] | nil, timeout :: non_neg_integer() | :infinity) ::
          boolean
  def set_lock(key, nodes \\ nil, timeout \\ :infinity) do
    nodes = nodes || Node.list([:this, :visible])

    case Utils.whereis_lock(key, nodes) do
      {on_behalf_of, _owner} when on_behalf_of == self() ->
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
      nil -> true
      {_on_behalf_of, {owner_pid, _lock_ref}} -> GenServer.call(owner_pid, :del_lock, :infinity)
    end
  end
end
