defmodule FastGlobalLock do
  @external_resource "README.md"
  @moduledoc File.read!("README.md")
             |> String.replace(~r/^.*?(?=`FastGlobalLock` is a library that)/s, "")
             |> String.replace("> [!WARNING]", "> #### Warning {: .warning}")
             |> String.replace("> [!IMPORTANT]", "> #### Important {: .info}")

  alias FastGlobalLock.Internal.LockHolder
  alias FastGlobalLock.Internal.Utils

  @typedoc "See `lock/2` for options' description."
  @type options :: [
          timeout: timeout(),
          nodes: [node()],
          nest?: boolean()
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

  ## Options

  - `:timeout` - a millisecond timeout after which the operation will fail. Defaults to `:infinity`
  - `:nodes` - nodes to lock on. Defaults to `Node.list([:this, :visible])`.
  - `:nest?` - whether to increment the lock-count if the lock is already held by the current process.
    Defaults to `true`.
  """
  @spec lock(key :: any(), timeout() | options()) :: boolean()
  def lock(key, timeout_or_options \\ []) do
    options = options(timeout_or_options)
    nodes = options[:nodes]
    timeout = options[:timeout]
    nest? = options[:nest?]

    case Utils.whereis_lock(key, nodes) do
      {on_behalf_of, {owner_pid, _lock_ref}} when on_behalf_of == self() ->
        if nest?, do: GenServer.cast(owner_pid, :nest_lock)
        true

      _ when timeout == 0 ->
        case GenServer.start_link(LockHolder, {key, nodes, self(), 0}) do
          {:ok, _lock_holder} -> true
          :ignore -> false
        end

      _ ->
        {:ok, lock_holder} = GenServer.start_link(LockHolder, {key, nodes, self(), timeout})
        GenServer.call(lock_holder, :set_lock, :infinity)
    end
  end

  @doc """
  Same as `lock/2`, but raises `FastGlobalLock.LockTimeoutError` if the lock is not acquired within
  the timeout.
  """
  @spec lock!(key :: any(), timeout() | options()) :: true | no_return()
  def lock!(key, timeout_or_options \\ []) do
    options = options(timeout_or_options)

    with false <- lock(key, options) do
      raise FastGlobalLock.LockTimeoutError,
        key: key,
        nodes: options[:nodes],
        timeout: options[:timeout]
    end
  end

  @doc """
  Synchronously releases the lock on `key`.

  Unlike `:global.del_lock/2`, this function needs to be called the same number of times as `lock/2`
  was called to acquire the lock.

  Returns:
  - `:ok` if the lock was released
  - `{:error, :not_owner}` if the current process is not the owner of the lock
  - `{:error, :not_locked}` if the lock is not held by any process.

  #### Important {: .info}

  Unlike `m::global.del_lock/2`, `unlock/2` will release the lock on every node it was acquired with
  `lock/2`.

  The `:nodes` option given to this function is only used to determine the lock holder
  process, and does not have to exactly match the nodes list used with `lock/2`.

  ## Options

  - `:nodes` - the nodes to unlock on. Defaults to all visible nodes.
  """
  @spec unlock(key :: any(), nodes: [node()]) :: :ok | {:error, :not_owner | :not_locked}
  def unlock(key, options \\ []) do
    nodes = Keyword.get_lazy(options, :nodes, fn -> nodes() end)

    self = self()

    case Utils.whereis_lock(key, nodes) do
      {^self, {owner_pid, _lock_ref}} -> GenServer.call(owner_pid, :del_lock, :infinity)
      {_on_behalf_of, _owner} -> {:error, :not_owner}
      nil -> {:error, :not_locked}
    end
  end

  @doc """
  Acquires a lock on `key` and calls `fun` while the lock is held.
  The lock is released after `fun` finishes, whether it returns normally or with
  an exception/signal.

  Returns `{:ok, result}` if the lock was acquired and `fun` returned normally,
  or `{:error, :lock_timeout}` if the lock was not acquired within the timeout.

  See `lock/2` for more details on options taken by this function.
  """
  @spec with_lock(key :: any(), timeout() | options(), (-> any())) ::
          {:ok, any()} | {:error, :lock_timeout}
  def with_lock(key, timeout_or_options \\ [], fun) do
    options = options(timeout_or_options)

    if lock(key, options),
      do: {:ok, do_with_unlock(key, options, fun)},
      else: {:error, :lock_timeout}
  end

  @doc """
  Same as `with_lock/3`, but raises `FastGlobalLock.LockTimeoutError` if the lock is not acquired
  within the timeout.
  """
  @spec with_lock!(key :: any(), timeout() | options(), (-> any())) :: any() | no_return()
  def with_lock!(key, timeout_or_options \\ [], fun) do
    options = options(timeout_or_options)

    lock!(key, options)
    do_with_unlock(key, options, fun)
  end

  defp do_with_unlock(key, options, fun) do
    fun.()
  after
    unlock(key, options)
  end

  defp options(timeout) when is_integer(timeout) or timeout == :infinity,
    do: options(timeout: timeout)

  defp options(options) when is_list(options) do
    [timeout: :infinity, nest?: true]
    |> Keyword.merge(options)
    |> Keyword.put_new_lazy(:nodes, fn -> nodes() end)
  end

  # Compatibility Interface

  @typedoc "See `t::global.id/0`. `LockRequesterId` is ignored."
  @type global_id :: {resource_id :: any(), lock_requester_id :: any()}

  @typedoc "See `t::global.retries/0`. Translated to a millisecond timeout."
  @type global_retries :: :infinity | non_neg_integer()

  @doc """
  `m::global`-compatible interface for `lock/2`.

  #### Equivalent to
  ```elixir
  FastGlobalLock.set_lock(id, Node.list([:this, :visible]), :infinity)
  ```
  """
  @doc group: "Compatibility Interface"
  @spec set_lock(global_id()) :: boolean()
  def set_lock(id),
    do: set_lock(id, nodes(), :infinity)

  @doc """
  `m::global`-compatible interface for `lock/2`.

  The `id` argument has to be a tuple of `{resource_id, lock_requester_id}`. `lock_requester_id` is
  ignored by `FastGlobalLock`.

  The number of `retries` is translated to the (average) timeout that `m::global` would sleep before
  giving up:

  | **Retries** | 0 | 1 | 2 | 3 | 4 | 5 + n |
  | **Timeout** | 0ms | 125ms | 375ms | 875ms | 1875ms | 3875ms + n*4000ms |

  #### Equivalent to

  ```elixir
  timeout = global_retries_to_timeout(retries)
  FastGlobalLock.lock(resource_id, nodes: nodes, timeout: timeout, nest?: false)
  ```
  """
  @doc group: "Compatibility Interface"
  @spec set_lock(global_id(), [node()], global_retries()) :: boolean()
  def set_lock({key, _requester}, nodes, retries \\ :infinity),
    do: lock(key, nodes: nodes, timeout: global_retries_to_timeout(retries))

  @doc """
  `m::global`-compatible interface for `unlock/2`.

  #### Equivalent to

  ```elixir
  FastGlobalLock.del_lock(id, Node.list([:this, :visible]))
  ```
  """
  @doc group: "Compatibility Interface"
  @spec del_lock(global_id()) :: true
  def del_lock(id),
    do: del_lock(id, nodes())

  @doc """
  `m::global`-compatible interface for `unlock/2`.

  The `id` argument has to be a tuple of `{resource_id, lock_requester_id}`. `lock_requester_id` is
  ignored by `FastGlobalLock`.

  This function will fully unlock `resource_id` no matter how many times it was nested, and will
  always return `true`.

  See `unlock/2` for more details on how the `:nodes` option is used.
  """
  @doc group: "Compatibility Interface"
  @spec del_lock(global_id(), [node()]) :: true
  def del_lock({key, _requester}, nodes) do
    Stream.repeatedly(fn -> unlock(key, nodes: nodes) end)
    |> Stream.take_while(&(&1 == :ok))
    |> Stream.run()

    true
  end

  @doc """
  `m::global`-compatible interface for `with_lock/3`.

  #### Equivalent to

  ```elixir
  FastGlobalLock.trans(id, fun, Node.list([:this, :visible]), :infinity)
  ```
  """
  @doc group: "Compatibility Interface"
  @spec trans(global_id(), (-> any())) :: any() | :aborted
  def trans(id, fun),
    do: trans(id, fun, nodes(), :infinity)

  @doc """
  `m::global`-compatible interface for `with_lock/3`.

  The `id` argument has to be a tuple of `{resource_id, lock_requester_id}`. `lock_requester_id` is
  ignored by `FastGlobalLock`.

  #### Important {: .info}

  Note that this function will only decrement the lock-count by one.
  If `lock/2` was previously called on this `key` with `nest?: true` (default), then the lock will
  still be held after `fun` finishes.

  To avoid clashing semantics, `m::global`-compatible interface *should not be mixed* with
  `FastGlobalLock`'s native API.

  #### Equivalent to

  ```elixir
  timeout = global_retries_to_timeout(retries)
  FastGlobalLock.with_lock(key, [nodes: nodes, timeout: timeout, nest?: false], fun)
  ```
  """
  @doc group: "Compatibility Interface"
  @spec trans(global_id(), (-> any()), [node()], global_retries()) :: any() | :aborted
  def trans({key, _requester}, fun, nodes, retries \\ :infinity) do
    timeout = global_retries_to_timeout(retries)

    case with_lock(key, [nodes: nodes, timeout: timeout, nest?: false], fun) do
      {:ok, result} -> result
      {:error, :lock_timeout} -> :aborted
    end
  end

  defp nodes,
    do: Node.list([:this, :visible])

  defp global_retries_to_timeout(retries) do
    # Translates :global.retries() to an average millisecond timeout they correspond to.
    # :global uses a random sleep between 0 and 1/4, 1/2, 1, 2, 4, 8, 8, 8, ... seconds, depending
    # on which retry we're on.
    case retries do
      :infinity -> :infinity
      0 -> 0
      1 -> 125
      2 -> 375
      3 -> 875
      4 -> 1875
      x when x >= 5 -> 3875 + (x - 5) * 4000
    end
  end
end
