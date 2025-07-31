defmodule FastGlobalLock.LockTimeoutError do
  defexception [:key, :nodes, :timeout]
  @type t :: %__MODULE__{key: term(), nodes: [node()], timeout: timeout()}

  @impl Exception
  def message(%__MODULE__{} = err) do
    "transaction for key #{inspect(err.key)} timed out after #{inspect(err.timeout)}ms"
  end
end
