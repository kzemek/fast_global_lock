ExUnit.configure(exclude: [type: :load])
ExUnit.start()

defmodule FastGlobalLock.TestHelper do
  def start_node do
    node_name =
      :"test_#{:erlang.unique_integer([:positive, :monotonic])}@localhost"

    {:ok, _peer, node} = :peer.start_link(%{name: node_name, wait_boot: 10_000, longnames: false})

    paths = :code.get_path()
    :erpc.call(node, :code, :add_paths, [paths])

    node
  end
end
