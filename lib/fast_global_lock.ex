defmodule FastGlobalLock do
  alias FastGlobalLock.Internal.LockHolder
  alias FastGlobalLock.Internal.Utils

  @spec set_lock(key :: term()) :: boolean()
  def set_lock(key), do: set_lock(key, nodes(), :infinity)

  @spec set_lock(key :: term(), [node()] | timeout()) :: boolean()
  def set_lock(key, node_or_timeout)
  def set_lock(key, [node | _] = nodes) when is_atom(node), do: set_lock(key, nodes, :infinity)
  def set_lock(key, timeout) when is_integer(timeout), do: set_lock(key, nodes(), timeout)
  def set_lock(key, :infinity), do: set_lock(key, nodes(), :infinity)

  @spec set_lock(key :: term(), [node()], timeout()) :: boolean()
  def set_lock(key, [node | _] = nodes, timeout)
      when is_atom(node) and (is_integer(timeout) or timeout == :infinity) do
    case Utils.whereis_lock(key, nodes) do
      {on_behalf_of, {owner_pid, _lock_ref}} when on_behalf_of == self() ->
        GenServer.cast(owner_pid, :nest_lock)
        true

      _ ->
        {:ok, lock_holder} = GenServer.start_link(LockHolder, {key, nodes})
        GenServer.call(lock_holder, {:set_lock, timeout}, :infinity)
    end
  end

  @spec del_lock(key :: term()) :: boolean()
  def del_lock(key), do: del_lock(key, nodes())

  @spec del_lock(key :: term(), [node()]) :: boolean()
  def del_lock(key, [node | _] = nodes) when is_atom(node) do
    case Utils.whereis_lock(key, nodes) do
      {on_behalf_of, {owner_pid, _lock_ref}} when on_behalf_of == self() ->
        GenServer.call(owner_pid, :del_lock, :infinity)

      _ ->
        true
    end
  end

  @spec trans(key :: term(), (-> any())) :: any() | :aborted
  def trans(key, fun), do: trans(key, fun, nodes(), :infinity)

  @spec trans(key :: term(), (-> any()), [node()] | timeout()) :: boolean()
  def trans(key, fun, node_or_timeout)
  def trans(key, fun, [nod | _] = nodes) when is_atom(nod), do: trans(key, fun, nodes, :infinity)
  def trans(key, fun, timeout) when is_integer(timeout), do: trans(key, fun, nodes(), timeout)
  def trans(key, fun, :infinity), do: trans(key, fun, nodes(), :infinity)

  @spec trans(key :: term(), (-> any()), [node()], timeout()) :: any() | :aborted
  def trans(key, fun, [node | _] = nodes, timeout)
      when is_atom(node) and (is_integer(timeout) or timeout == :infinity) do
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

  defp nodes, do: Node.list([:this, :visible])
end
