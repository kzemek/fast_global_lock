defmodule FastGlobalLock do
  @external_resource "README.md"
  @moduledoc File.read!("README.md")
             |> String.replace(~r/^.*?(?=`FastGlobalLock` is a library that)/s, "")
             |> String.replace("> [!WARNING]", "> #### Warning {: .warning}")
             |> String.replace("> [!IMPORTANT]", "> #### Important {: .info}")

  alias FastGlobalLock.Internal.LockHolder
  alias FastGlobalLock.{LockTimeoutError, NodesMismatchError}

  import Record, only: [defrecordp: 2]

  defrecordp :lock_info, lock_holder: nil, nodes: nil, count: 1

  @typep lock_info ::
           record(:lock_info, lock_holder: pid(), nodes: [node()], count: pos_integer())

  @typedoc "See `lock/2` for options' description."
  @type options :: [
          timeout: timeout(),
          nodes: [node()],
          on_nodes_mismatch: :ignore | :raise | :raise_if_minority_overlap
        ]

  @doc """
  Sets a `m::global` lock on `key` for the current process.

  This function is synchronous and will either return `true` if the lock was acquired, or `false`
  if the lock was not acquired within the timeout.

  As with `:global.set_lock/3`, if a process that holds a lock dies, or the node goes down,
  the locks held by the process are released.

  If the lock is already held by the current process, `lock/2` will return `true` and increment
  the lock-count. While the current process is alive, it must call `unlock/2` the same number
  of times to release the lock.

  #### Important {: .info}

  If a key is already locked by this process, `FastGlobalLock` will not allow another lock to be
  acquired, even if given a different set of nodes. See `:on_nodes_mismatch` option.

  ## Options

  - `:timeout` - a millisecond timeout after which the operation will fail. Defaults to `:infinity`
  - `:nodes` - nodes to lock on. Defaults to `Node.list([:this, :visible])`.
  - `:on_nodes_mismatch` - what to do if the lock is already held by this process on a different
    set of nodes:
    - `:ignore` - increment the lock-count without raising an error
    - `:raise` - raise `FastGlobalLock.NodesMismatchError`
    - `:raise_if_disjoint` - raise `FastGlobalLock.NodesMismatchError` if the requested `:nodes`
      have no overlap with the existing lock's `:nodes`. Otherwise increment the lock-count.
      This is the default setting.

    #### Example

        # Acquire the first lock
        FastGlobalLock.lock(:foo, nodes: [:a, :b])

        # Raises an error because of the nodes mismatch
        # This would also happen if we didn't provide the `:nodes` option and the cluster membership
        # changed between the first and second lock
        FastGlobalLock.lock(:foo, nodes: [:a, :b, :c], on_nodes_mismatch: :raise)

        # Won't fail as there's an overlap [:a] node with the existing lock's `nodes: [:a, :b]`
        FastGlobalLock.lock(:foo, nodes: [:a, :c], on_nodes_mismatch: :raise_if_disjoint)

        # Raises an error because the nodes are disjoint with the existing lock's `nodes: [:a, :b]`
        FastGlobalLock.lock(:foo, nodes: [:c, :d], on_nodes_mismatch: :raise_if_disjoint)

        # Won't fail no matter what the requested `:nodes` are
        FastGlobalLock.lock(:foo, nodes: [:c, :d], on_nodes_mismatch: :ignore)
  """
  @spec lock(key :: any(), timeout() | options()) :: boolean()
  def lock(key, timeout_or_options \\ []) do
    options = ensure_options(timeout_or_options)
    nodes = options[:nodes]
    timeout = options[:timeout]

    with nil <- process_dict_get_lock(key),
         lock_info() = lock <- do_lock(key, nodes, timeout) do
      process_dict_put_lock(key, lock)
      true
    else
      lock_info(nodes: existing_nodes, count: count) = existing_lock ->
        if nodes_mismatch?(options[:on_nodes_mismatch], existing_nodes, nodes) do
          raise NodesMismatchError,
            key: key,
            owner: self(),
            existing_nodes: existing_nodes,
            requested_nodes: nodes
        end

        process_dict_put_lock(key, lock_info(existing_lock, count: count + 1))
        true

      nil ->
        false
    end
  end

  @doc """
  Same as `lock/2`, but raises `FastGlobalLock.LockTimeoutError` if the lock is not acquired within
  the timeout.
  """
  @spec lock!(key :: any(), timeout() | options()) :: true | no_return()
  def lock!(key, timeout_or_options \\ []) do
    options = ensure_options(timeout_or_options)

    with false <- lock(key, options) do
      raise LockTimeoutError, key: key, nodes: options[:nodes], timeout: options[:timeout]
    end
  end

  @doc """
  Decrements the lock-count for `key`.

  If the lock-count is decremented to 0, the lock is synchronously released.

  Returns `true` if the lock-count was decremented, `false` if the lock is not held by the current
  process.
  """
  @spec unlock(key :: any()) :: boolean()
  def unlock(key) do
    case process_dict_get_lock(key) do
      lock_info(count: count) = lock_info when count > 1 ->
        process_dict_put_lock(key, lock_info(lock_info, count: count - 1))
        true

      lock_info(lock_holder: lock_holder) ->
        GenServer.call(lock_holder, :del_lock, :infinity)
        process_dict_del_lock(key)
        true

      nil ->
        false
    end
  end

  @doc """
  Acquires a lock on `key` and calls `fun` while the lock is held.
  The lock is released after `fun` finishes, whether it returns normally or with
  an exception/signal.

  Returns `{:ok, result}` if the lock was acquired and `fun` returned `result`,
  or `{:error, :lock_timeout}` if the lock was not acquired within the timeout.

  See `lock/2` for more details on options taken by this function.
  """
  @spec with_lock(key :: any(), timeout() | options(), (-> result)) ::
          {:ok, result} | {:error, :lock_timeout}
        when result: any()
  def with_lock(key, timeout_or_options \\ [], fun) do
    options = ensure_options(timeout_or_options)

    if lock(key, options),
      do: {:ok, do_with_unlock(key, fun)},
      else: {:error, :lock_timeout}
  end

  @doc """
  Same as `with_lock/3`, but raises `FastGlobalLock.LockTimeoutError` if the lock is not acquired
  within the timeout.
  """
  @spec with_lock!(key :: any(), timeout() | options(), (-> result)) :: result | no_return()
        when result: any()
  def with_lock!(key, timeout_or_options \\ [], fun) do
    options = ensure_options(timeout_or_options)

    lock!(key, options)
    do_with_unlock(key, fun)
  end

  defp do_with_unlock(key, fun) do
    fun.()
  after
    unlock(key)
  end

  @spec do_lock(key :: any(), nodes :: [node()], timeout()) :: lock_info() | nil
  defp do_lock(key, nodes, 0 = _timeout) do
    case GenServer.start_link(LockHolder, {key, nodes, self(), 0}) do
      {:ok, lock_holder} -> lock_info(lock_holder: lock_holder, nodes: nodes)
      :ignore -> nil
    end
  end

  defp do_lock(key, nodes, timeout) do
    {:ok, lock_holder} = GenServer.start_link(LockHolder, {key, nodes, self(), timeout})

    if GenServer.call(lock_holder, :set_lock, :infinity),
      do: lock_info(lock_holder: lock_holder, nodes: nodes)
  end

  defp nodes_mismatch?(:ignore, _existing_nodes, _requested_nodes),
    do: false

  defp nodes_mismatch?(:raise, existing_nodes, requested_nodes),
    do: existing_nodes != requested_nodes

  defp nodes_mismatch?(:raise_if_disjoint, existing_nodes, requested_nodes),
    do: :ordsets.intersection(existing_nodes, requested_nodes) == []

  @spec ensure_options(timeout() | options()) :: options()
  defp ensure_options(timeout) when is_integer(timeout) or timeout == :infinity,
    do: ensure_options(timeout: timeout)

  defp ensure_options(options) when is_list(options) do
    [timeout: :infinity, on_nodes_mismatch: :raise_if_disjoint]
    |> Keyword.merge(options)
    |> Keyword.put_new_lazy(:nodes, fn -> Node.list([:this, :visible]) end)
    |> Keyword.update!(:nodes, &:ordsets.from_list/1)
  end

  @spec process_dict_get_lock(key :: any()) :: lock_info() | nil
  defp process_dict_get_lock(key),
    do: Process.get({__MODULE__, :lock, key})

  @spec process_dict_put_lock(key :: any(), lock_info()) :: :ok
  defp process_dict_put_lock(key, lock_info() = lock_info) do
    Process.put({__MODULE__, :lock, key}, lock_info)
    :ok
  end

  @spec process_dict_del_lock(key :: any()) :: :ok
  defp process_dict_del_lock(key) do
    Process.delete({__MODULE__, :lock, key})
    :ok
  end
end
