defmodule FastGlobalLockTest do
  use ExUnit.Case, async: true

  alias FastGlobalLock

  describe "basic lock operations" do
    test "can acquire and release lock" do
      key = make_ref()

      assert true = FastGlobalLock.lock(key)
      assert :ok = FastGlobalLock.unlock(key)
    end

    test "second process cannot acquire held lock" do
      key = make_ref()

      assert true = FastGlobalLock.lock(key)

      refute in_new_process(fn -> FastGlobalLock.lock(key, 0) end)

      assert :ok = FastGlobalLock.unlock(key)
    end

    test "second process can acquire lock after release" do
      key = make_ref()

      assert true = FastGlobalLock.lock(key)
      assert :ok = FastGlobalLock.unlock(key)

      assert true = in_new_process(fn -> FastGlobalLock.lock(key, 0) end)
    end

    test "lock between different processes" do
      key = make_ref()

      {:ok, pid1} = Agent.start(fn -> FastGlobalLock.lock(key) end)

      assert FastGlobalLock.lock(key, 0) == false

      Agent.update(pid1, fn _ -> FastGlobalLock.unlock(key) end)

      assert FastGlobalLock.lock(key, 0) == true
    end
  end

  describe "timeout behavior" do
    test "immediate timeout returns false when lock is held" do
      key = make_ref()

      {:ok, _holder_pid} = Agent.start(fn -> FastGlobalLock.lock(key) end)

      {us, _} =
        :timer.tc(
          fn ->
            refute FastGlobalLock.lock(key, 0)
            refute FastGlobalLock.lock(key, timeout: 0)
          end,
          :microsecond
        )

      assert us < 1000
    end

    test "lock succeeds when timeout is sufficient" do
      key = make_ref()

      {:ok, holder_pid} = Agent.start(fn -> FastGlobalLock.lock(key) end)

      task = Task.async(fn -> FastGlobalLock.lock(key, 500) end)

      Agent.cast(holder_pid, fn _ ->
        Process.sleep(1)
        FastGlobalLock.unlock(key)
      end)

      {us, _} = :timer.tc(fn -> assert Task.await(task) end, :microsecond)
      assert us < 2000
    end

    test "lock fails when timeout expires" do
      key = make_ref()

      {:ok, _holder_pid} = Agent.start(fn -> FastGlobalLock.lock(key) end)

      refute FastGlobalLock.lock(key, 50)
    end
  end

  describe "nested locking" do
    test "same process can acquire lock multiple times" do
      key = make_ref()

      assert true = FastGlobalLock.lock(key)
      assert true = FastGlobalLock.lock(key)
      assert true = FastGlobalLock.lock(key)

      assert :ok = FastGlobalLock.unlock(key)
      assert :ok = FastGlobalLock.unlock(key)
      assert :ok = FastGlobalLock.unlock(key)

      assert {:error, :not_locked} = FastGlobalLock.unlock(key)
    end

    test "other processes cannot acquire lock while any nests remain" do
      key = make_ref()

      # Acquire lock multiple times
      assert true = FastGlobalLock.lock(key)
      assert true = FastGlobalLock.lock(key)

      # Other process cannot acquire
      refute in_new_process(fn -> FastGlobalLock.lock(key, 0) end)

      # Unlock once - other process still cannot acquire
      assert :ok = FastGlobalLock.unlock(key)
      refute in_new_process(fn -> FastGlobalLock.lock(key, 0) end)

      # Unlock again - now other process can acquire
      assert :ok = FastGlobalLock.unlock(key)
      assert true = in_new_process(fn -> FastGlobalLock.lock(key, 0) end)
    end
  end

  describe "with_lock functions" do
    test "with_lock! succeeds when lock is available" do
      key = make_ref()

      assert :success = FastGlobalLock.with_lock!(key, fn -> :success end)
      assert {:error, :success} = FastGlobalLock.with_lock!(key, fn -> {:error, :success} end)
      assert {:ok, :success} = FastGlobalLock.with_lock!(key, fn -> {:ok, :success} end)
    end

    test "with_lock! raises when lock times out" do
      key = make_ref()

      {:ok, _holder_pid} = Agent.start(fn -> FastGlobalLock.lock(key) end)

      assert_raise FastGlobalLock.LockTimeoutError, fn ->
        FastGlobalLock.with_lock!(key, [timeout: 1], fn ->
          :should_not_reach
        end)
      end
    end

    test "with_lock returns {:ok, result} when successful" do
      key = make_ref()

      assert {:ok, :success} =
               FastGlobalLock.with_lock(key, fn -> :success end)

      assert {:ok, {:error, :success}} =
               FastGlobalLock.with_lock(key, fn -> {:error, :success} end)

      assert {:ok, {:ok, :success}} =
               FastGlobalLock.with_lock(key, fn -> {:ok, :success} end)
    end

    test "with_lock returns {:error, :lock_timeout} when timeout" do
      key = make_ref()

      {:ok, _holder_pid} = Agent.start(fn -> FastGlobalLock.lock(key) end)

      assert {:error, :lock_timeout} =
               FastGlobalLock.with_lock(key, [timeout: 1], fn ->
                 :should_not_reach
               end)
    end

    test "with_lock automatically unlocks on success" do
      key = make_ref()

      assert {:ok, :success} =
               FastGlobalLock.with_lock(key, fn ->
                 # Verify we have the lock inside the function by testing from another process
                 refute in_new_process(fn -> FastGlobalLock.lock(key, 0) end)
                 :success
               end)

      assert true = in_new_process(fn -> FastGlobalLock.lock(key, 0) end)
    end

    test "with_lock automatically unlocks on exception" do
      key = make_ref()

      assert_raise RuntimeError, "test error", fn ->
        FastGlobalLock.with_lock!(key, fn ->
          raise "test error"
        end)
      end

      assert true = in_new_process(fn -> FastGlobalLock.lock(key, 0) end)
    end
  end

  describe "lock! function" do
    test "lock! returns true when successful" do
      key = make_ref()

      assert true = FastGlobalLock.lock!(key)
      assert :ok = FastGlobalLock.unlock(key)
    end

    test "lock! raises LockTimeoutError when timeout" do
      key = make_ref()

      {:ok, _holder_pid} = Agent.start(fn -> FastGlobalLock.lock(key) end)

      assert_raise FastGlobalLock.LockTimeoutError, fn ->
        FastGlobalLock.lock!(key, timeout: 50)
      end
    end
  end

  describe "global-compatible interface" do
    test "set_lock and del_lock work" do
      key = make_ref()
      global_id = {key, self()}

      assert true = FastGlobalLock.set_lock(global_id)
      assert true = FastGlobalLock.del_lock(global_id)

      # `del_lock` always returns true
      assert true = FastGlobalLock.del_lock(global_id)
    end

    test "set_lock with retries" do
      key = make_ref()
      global_id = {key, self()}

      {:ok, _holder_pid} = Agent.start(fn -> FastGlobalLock.set_lock(global_id) end)

      # Should fail with 0 retries
      {us, _} =
        :timer.tc(fn -> refute FastGlobalLock.set_lock(global_id, nil, 0) end, :microsecond)

      assert us < 1000

      {us, _} =
        :timer.tc(fn -> FastGlobalLock.set_lock(global_id, nil, 1) end, :millisecond)

      assert us in 125..374

      {us, _} =
        :timer.tc(fn -> FastGlobalLock.set_lock(global_id, nil, 2) end, :millisecond)

      assert us in 375..874
    end

    test "trans function" do
      key = make_ref()
      global_id = {key, self()}

      assert :transaction_result =
               FastGlobalLock.trans(global_id, fn -> :transaction_result end)
    end

    test "trans function with timeout" do
      key = make_ref()
      global_id = {key, self()}

      {:ok, _holder_pid} = Agent.start(fn -> FastGlobalLock.set_lock(global_id) end)

      assert :aborted =
               FastGlobalLock.trans(global_id, fn -> :should_not_reach end, nil, 0)
    end
  end

  describe "error conditions" do
    test "unlocking non-held lock is safe" do
      key = make_ref()
      assert {:error, :not_locked} = FastGlobalLock.unlock(key)
    end

    test "unlocking from wrong process is safe" do
      key = make_ref()

      {:ok, _holder_pid} = Agent.start(fn -> FastGlobalLock.lock(key) end)

      assert {:error, :not_owner} = FastGlobalLock.unlock(key)
      refute FastGlobalLock.lock(key, 0)
    end
  end

  defp in_new_process(fun),
    do: fun |> Task.async() |> Task.await()
end
