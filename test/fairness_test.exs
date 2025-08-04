defmodule FastGlobalLock.FairnessTest do
  use ExUnit.Case, async: true

  alias FastGlobalLock

  describe "fairness and ordering" do
    test "waiters eventually get the lock" do
      key = make_ref()

      # Start multiple waiters
      tasks =
        for _ <- 1..3 do
          Task.async(fn ->
            result = FastGlobalLock.lock(key, 2000)

            if result do
              # Hold briefly
              Process.sleep(50)
              true = FastGlobalLock.unlock(key)
            end

            result
          end)
        end

      # All should eventually succeed
      assert tasks |> Task.await_many() |> Enum.all?(&(&1 == true))
    end

    test "approximate FIFO ordering under normal conditions" do
      key = make_ref()

      # Start holder that will release lock after waiters are registered
      {:ok, holder_task} =
        Agent.start(fn ->
          assert FastGlobalLock.lock(key) == true
        end)

      # Start waiters in sequence with small delays
      waiter_tasks =
        for _ <- 1..100 do
          # Stagger the waiter starts
          Process.sleep(1)

          Task.async(fn ->
            start_time = System.monotonic_time()
            result = FastGlobalLock.lock(key, 3000)
            end_time = System.monotonic_time()

            if result do
              # Hold briefly
              Process.sleep(1)
              true = FastGlobalLock.unlock(key)
            end

            {result, start_time, end_time}
          end)
        end

      # Give all waiters time to register
      Process.sleep(10)

      # Release the holder
      Agent.update(holder_task, fn _ -> FastGlobalLock.unlock(key) end)

      # All waiters should succeed
      results = Task.await_many(waiter_tasks)
      assert Enum.all?(results, fn {result, _, _} -> result == true end)

      # Verify that waiters that started earlier generally got the lock earlier
      sorted_by_start = Enum.sort_by(results, fn {_, start_time, _end_time} -> start_time end)
      sorted_by_acquisition = Enum.sort_by(results, fn {_, _start_time, end_time} -> end_time end)

      equal_runs =
        List.myers_difference(sorted_by_start, sorted_by_acquisition)
        |> Enum.sum_by(fn
          {:eq, elems} -> length(elems)
          {_op, _elems} -> 0
        end)

      # 90% of aquisitions should be in correct order
      assert equal_runs >= 90
    end

    test "no starvation under moderate contention" do
      key = make_ref()

      # Start many waiters
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            for _ <- 1..100 do
              result = FastGlobalLock.lock(key, 5000)

              if result do
                # Hold briefly
                Process.sleep(1)
                true = FastGlobalLock.unlock(key)
              end

              result
            end
          end)
        end

      # All should eventually succeed (no starvation)
      assert tasks |> Task.await_many() |> Enum.concat() |> Enum.all?(&(&1 == true))
    end

    test "fairness with transaction calls" do
      key = make_ref()

      # Start multiple transactions
      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            result =
              FastGlobalLock.with_lock(key, [timeout: 3000], fn ->
                # Simulate work
                Process.sleep(30)
              end)

            case result do
              {:ok, _value} -> true
              {:error, :lock_timeout} -> false
            end
          end)
        end

      # All should eventually succeed
      assert tasks |> Task.await_many() |> Enum.all?(&(&1 == true))
    end
  end
end
