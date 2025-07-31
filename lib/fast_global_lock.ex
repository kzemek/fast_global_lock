defmodule FastGlobalLock do
  alias FastGlobalLock.Internal.LockHolder
  alias FastGlobalLock.Internal.Utils

  @type options :: [
          timeout: timeout(),
          nodes: [node()]
        ]

  @spec lock(key :: any(), timeout() | options()) :: boolean()
  def lock(key, timeout_or_options \\ []) do
    options = options(timeout_or_options)
    nodes = options[:nodes]
    timeout = options[:timeout]

    case Utils.whereis_lock(key, nodes) do
      {on_behalf_of, {owner_pid, _lock_ref}} when on_behalf_of == self() ->
        GenServer.cast(owner_pid, :nest_lock)
        true

      _ ->
        {:ok, lock_holder} = GenServer.start_link(LockHolder, {key, nodes})
        GenServer.call(lock_holder, {:set_lock, timeout}, :infinity)
    end
  end

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

  @spec unlock(key :: any(), options()) :: :ok
  def unlock(key, options \\ []) do
    nodes = Keyword.get_lazy(options, :nodes, fn -> nodes() end)

    with {on_behalf_of, {owner_pid, _lock_ref}} when on_behalf_of == self() <-
           Utils.whereis_lock(key, nodes),
         do: GenServer.call(owner_pid, :del_lock, :infinity)

    :ok
  end

  @spec with_lock!(key :: any(), timeout() | options(), (-> any())) :: any() | no_return()
  def with_lock!(key, timeout_or_options \\ [], fun) do
    options = options(timeout_or_options)

    lock!(key, options)
    do_with_unlock(key, options, fun)
  end

  @spec with_lock(key :: any(), timeout() | options(), (-> any())) ::
          {:ok, any()} | {:error, :lock_timeout}
  def with_lock(key, timeout_or_options \\ [], fun) do
    options = options(timeout_or_options)

    if lock(key, options),
      do: {:ok, do_with_unlock(key, options, fun)},
      else: {:error, :lock_timeout}
  end

  defp do_with_unlock(key, options, fun) do
    fun.()
  after
    unlock(key, options)
  end

  defp options(timeout) when is_integer(timeout) or timeout == :infinity,
    do: options(timeout: timeout)

  defp options(options) when is_list(options) do
    [timeout: :infinity]
    |> Keyword.merge(options)
    |> Keyword.put_new_lazy(:nodes, fn -> nodes() end)
  end

  # `:global`-compatible interface

  @type global_id :: {resource_id :: any(), lock_requester_id :: any()}
  @type global_retries :: :infinity | non_neg_integer()

  @spec set_lock(global_id(), [node()] | nil, global_retries()) :: boolean()
  def set_lock({key, _requester}, nodes \\ nil, retries \\ :infinity) do
    timeout = global_retries_to_timeout(retries)
    lock(key, nodes: nodes || nodes(), timeout: timeout)
  end

  @spec del_lock(global_id(), [node()] | nil) :: true
  def del_lock({key, _requester}, nodes \\ nil) do
    unlock(key, nodes: nodes || nodes())
    true
  end

  @spec trans(global_id(), (-> any()), [node()] | nil, global_retries()) :: any() | :aborted
  def trans({key, _requester}, fun, nodes \\ nil, retries \\ :infinity) do
    timeout = global_retries_to_timeout(retries)

    case with_lock(key, [nodes: nodes || nodes(), timeout: timeout], fun) do
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
