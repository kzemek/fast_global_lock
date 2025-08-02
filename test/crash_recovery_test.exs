defmodule FastGlobalLock.CrashRecoveryTest do
  use ExUnit.Case, async: true

  alias FastGlobalLock

  describe "crash recovery" do
    test "lock is released when locking process dies" do
      key = make_ref()

      # Start a process that acquires lock then dies
      {:ok, pid} = Agent.start(fn -> FastGlobalLock.lock(key) end)

      # Can't acquire a lock that's already held
      refute FastGlobalLock.lock(key, 0)

      Agent.stop(pid, :kill)

      # Another process should be able to acquire the lock
      assert FastGlobalLock.lock(key, 0)
    end

    test "lock is released when holder process dies" do
      key = make_ref()

      # Start a process that acquires lock then dies
      {:ok, pid} = Agent.start(fn -> FastGlobalLock.lock(key) end)

      # Can't acquire a lock that's already held
      refute FastGlobalLock.lock(key, 0)

      {^pid, {holder_pid, _}} = FastGlobalLock.Internal.Utils.whereis_lock(key, [node()])

      Process.exit(holder_pid, :kill)

      # The locking process should also die
      assert match?(
               {reason, _} when reason in [:killed, :noproc],
               catch_exit(Agent.get(pid, fn _ -> Process.sleep(1) end))
             )

      # Another process should be able to acquire the lock
      assert FastGlobalLock.lock(key, 0)
    end

    test "waiting processes are notified when locker dies" do
      key = make_ref()

      # First process acquires lock
      {:ok, holder_pid} = Agent.start(fn -> FastGlobalLock.lock(key) end)

      # Second process waits for lock
      waiter_task = Task.async(fn -> FastGlobalLock.lock(key, 2000) end)

      # Give waiter time to start waiting
      Process.sleep(1)

      Agent.stop(holder_pid, :kill)

      # Waiter should immediately get the lock
      assert Task.await(waiter_task, 1)
    end

    test "multiple waiters are handled when locker dies" do
      key = make_ref()

      # First process acquires lock
      {:ok, holder_pid} = Agent.start(fn -> FastGlobalLock.lock(key) end)

      # Multiple processes wait for lock
      waiter_tasks = for _ <- 1..255, do: Task.async(fn -> FastGlobalLock.lock(key, 3000) end)

      # Give waiters time to start waiting
      Process.sleep(1)

      # Kill the holder
      Agent.stop(holder_pid, :kill)

      # All waiters should eventually succeed
      assert waiter_tasks |> Task.await_many() |> Enum.all?(&(&1 == true))
    end

    test "transaction is aborted when locking process dies during execution" do
      key = make_ref()
      parent = self()

      # Start a process that begins transaction then dies
      pid =
        spawn(fn ->
          FastGlobalLock.with_lock!(key, fn ->
            send(parent, :trans_started)
            Process.sleep(:infinity)
          end)
        end)

      assert_receive :trans_started, 1000

      # Kill the process
      Process.exit(pid, :kill)

      # Another process should be able to acquire the lock
      assert :success = FastGlobalLock.with_lock!(key, fn -> :success end)
    end

    test "nested lock counts are reset on crash" do
      key = make_ref()

      # Start a process that acquires nested locks then dies
      {:ok, pid} =
        Agent.start(fn ->
          assert FastGlobalLock.lock(key)
          assert FastGlobalLock.lock(key)
          assert FastGlobalLock.lock(key)
        end)

      # Kill the process
      Agent.stop(pid, :kill)

      # Another process should be able to acquire the lock immediately
      assert FastGlobalLock.lock(key, 1)
    end

    test "lock holder cleanup notifies correct peer on crash" do
      key = make_ref()

      # First process acquires lock
      {:ok, holder_pid} = Agent.start(fn -> assert FastGlobalLock.lock(key) end)

      # Start first waiter
      waiter1_task =
        Task.async(fn ->
          result = FastGlobalLock.lock(key, 3000)
          result_at = System.monotonic_time()
          if result, do: Process.sleep(10)
          {result, result_at}
        end)

      # Give first waiter time to register
      Process.sleep(1)

      # Start second waiter
      waiter2_task =
        Task.async(fn ->
          result = FastGlobalLock.lock(key, 3000)
          result_at = System.monotonic_time()
          if result, do: Process.sleep(10)
          {result, result_at}
        end)

      # Give second waiter time to register
      Process.sleep(1)

      # Kill the holder
      Agent.stop(holder_pid, :kill)

      # Both waiters should eventually succeed
      assert [{true, waiter1_locked_at}, {true, waiter2_locked_at}] =
               Task.await_many([waiter1_task, waiter2_task])

      # They should succeed in order
      assert waiter1_locked_at < waiter2_locked_at
    end
  end
end
