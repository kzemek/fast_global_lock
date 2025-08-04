defmodule FastGlobalLock.LockTimeoutError do
  @moduledoc """
  Raised by `FastGlobalLock.lock!/2` and `FastGlobalLock.with_lock!/3`
  when lock acquisition times out.
  """

  defexception [:key, :nodes, :timeout]

  @type t :: %__MODULE__{
          key: term(),
          nodes: [node()],
          timeout: timeout()
        }

  @impl Exception
  def message(%__MODULE__{} = err) do
    """
    lock attempt for key #{inspect(err.key)} on nodes #{inspect(err.nodes)} timed out after \
    #{inspect(err.timeout)}ms\
    """
  end
end
