defmodule FastGlobalLock.NodesMismatchError do
  @moduledoc """
  Raised when `FastGlobalLock.lock/2` (as well as `with_lock/3` and the bang! variants) is called
  on a key that is already locked by the current process for a different set of nodes.
  """

  defexception [:key, :owner, :existing_nodes, :requested_nodes]

  @type t :: %__MODULE__{
          key: term(),
          owner: pid(),
          existing_nodes: [node()],
          requested_nodes: [node()]
        }

  @impl Exception
  def message(%__MODULE__{} = err) do
    """
    lock for key #{inspect(err.key)} is held by process #{inspect(err.owner)} on nodes \
    #{inspect(err.existing_nodes)}, but is being re-locked on nodes #{inspect(err.requested_nodes)}\
    """
  end
end
