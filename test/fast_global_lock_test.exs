defmodule FastGlobalLockTest do
  use ExUnit.Case
  doctest FastGlobalLock

  test "greets the world" do
    assert FastGlobalLock.hello() == :world
  end
end
