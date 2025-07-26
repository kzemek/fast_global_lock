defmodule FastGlobalLock.Internal.Utils do
  @moduledoc false

  @type global_owner :: {pid(), reference()}

  @spec whereis_lock(term(), [node()]) :: {lock_requester_id :: term(), global_owner()} | nil
  def whereis_lock(resource, nodes) do
    lock =
      if node() in nodes,
        do: :ets.lookup(:global_locks, resource),
        else: :erpc.call(Enum.random(nodes), :ets, :lookup, [:global_locks, resource])

    case lock do
      [{^resource, lock_requester_id, [owner]}] -> {lock_requester_id, owner}
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
