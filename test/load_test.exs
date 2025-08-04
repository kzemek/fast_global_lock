{:module, _, helpers_bytecode, _} =
  defmodule FastGlobalLock.StressTest.RemoteHelpers do
    @moduledoc """
    Helper functions for remote nodes in stress tests.
    """

    defp microsleep(us),
      do: do_microsleep(:erlang.monotonic_time(:microsecond) + us)

    defp do_microsleep(until) do
      Process.sleep(0)
      time = :erlang.monotonic_time(:microsecond)
      if time < until, do: microsleep(until)
    end

    defp with_lock(time_collector, key, fun) do
      start = :os.perf_counter()
      FastGlobalLock.lock(key)
      locked = :os.perf_counter()
      fun.()
      unlocked = :os.perf_counter()
      FastGlobalLock.unlock(key)

      Agent.cast(time_collector, fn times ->
        [{:unlocked, unlocked}, {:locked, locked}, {:start, start} | times]
      end)
    end

    def start_task_supervisor do
      {:ok, sup} = Task.Supervisor.start_link(name: __MODULE__)
      Process.unlink(sup)
      sup
    end

    def cascade_task(time_collector, key) do
      with_lock(time_collector, key, fn -> microsleep(100) end)
    end

    def contention_task(time_collector, key) do
      Enum.each(1..100, fn _ ->
        with_lock(time_collector, key, fn -> nil end)
      end)
    end

    def slow_cascade_task(time_collector, key) do
      with_lock(time_collector, key, fn -> Process.sleep(10) end)
    end

    def timeout_task(time_collector, key) do
      start = :os.perf_counter()

      if FastGlobalLock.lock(key, 100) do
        locked = :os.perf_counter()
        unlocked = :os.perf_counter()
        FastGlobalLock.unlock(key)

        Agent.cast(time_collector, fn times ->
          [{:unlocked, unlocked}, {:locked, locked}, {:start, start} | times]
        end)
      end
    end

    def exit_task(time_collector, key) do
      with_lock(time_collector, key, fn ->
        Process.sleep(10)
        exit(:kill)
      end)
    end
  end

defmodule FastGlobalLock.StressTest do
  use ExUnit.Case, async: false

  alias FastGlobalLock
  alias FastGlobalLock.StressTest.RemoteHelpers
  alias FastGlobalLock.TestHelper

  @moduletag type: :load

  describe "local" do
    setup do
      {:ok, sup} = Task.Supervisor.start_link()
      %{local_task_sup: sup}
    end

    test "cascade", %{local_task_sup: this_sup} do
      cascade_test([this_sup])
    end

    test "contention", %{local_task_sup: this_sup} do
      contention_test([this_sup])
    end

    test "slow cascade with timeouts", %{local_task_sup: this_sup} do
      slow_cascade_with_timeouts_test([this_sup])
    end
  end

  describe "multi-node" do
    setup :start_nodes

    test "cascade", %{remote_task_sups: task_sups} do
      cascade_test(task_sups)
    end

    test "contention", %{remote_task_sups: task_sups} do
      contention_test(task_sups)
    end

    test "slow cascade with timeouts", %{remote_task_sups: task_sups} do
      slow_cascade_with_timeouts_test(task_sups)
    end
  end

  defp cascade_test(task_sups) do
    key = make_ref()

    {:ok, time_collector} = Agent.start_link(fn -> [] end)

    Benchee.run(
      %{
        cascade: fn {agent, tasks} ->
          Agent.cast(agent, fn _ -> FastGlobalLock.unlock(key) end)
          Task.await_many(tasks, :infinity)
        end
      },
      before_each: fn _ ->
        {:ok, agent} = Agent.start_link(fn -> FastGlobalLock.lock(key) end)

        tasks =
          for sup <- task_sups, _ <- 1..div(100, length(task_sups)) do
            Task.Supervisor.async(sup, RemoteHelpers, :cascade_task, [time_collector, key])
          end

        Process.sleep(1)
        {agent, tasks}
      end,
      formatters: [],
      print: %{benchmarking: false, configuration: false},
      time: 10
    )

    print_stats(time_collector)
  end

  defp contention_test(task_sups) do
    key = make_ref()

    {:ok, time_collector} = Agent.start_link(fn -> [] end)

    Benchee.run(
      %{
        contention: fn tasks -> Task.await_many(tasks, :infinity) end
      },
      formatters: [],
      print: %{benchmarking: false, configuration: false},
      before_each: fn _ ->
        for sup <- task_sups, _ <- 1..div(100, length(task_sups)) do
          Task.Supervisor.async(sup, RemoteHelpers, :contention_task, [time_collector, key])
        end
      end,
      time: 10
    )

    print_stats(time_collector)
  end

  defp slow_cascade_with_timeouts_test(task_sups) do
    key = make_ref()

    {:ok, time_collector} = Agent.start_link(fn -> [] end)

    Benchee.run(
      %{
        slow_cascade_with_timeouts: fn {agent, cascade_tasks, timeout_tasks} ->
          Agent.cast(agent, fn _ -> FastGlobalLock.unlock(key) end)
          Task.await_many(cascade_tasks, :infinity)
          Task.await_many(timeout_tasks, :infinity)
        end
      },
      before_each: fn _ ->
        {:ok, agent} = Agent.start_link(fn -> FastGlobalLock.lock(key) end)

        cascade_tasks =
          for sup <- task_sups, _ <- 1..div(100, length(task_sups)) do
            Task.Supervisor.async(sup, RemoteHelpers, :slow_cascade_task, [time_collector, key])
          end

        timeout_tasks =
          for sup <- task_sups, _ <- 1..div(2000, length(task_sups)) do
            Task.Supervisor.async(sup, RemoteHelpers, :timeout_task, [time_collector, key])
          end

        Process.sleep(1)
        {agent, cascade_tasks, timeout_tasks}
      end,
      formatters: [],
      print: %{benchmarking: false, configuration: false},
      time: 10
    )

    print_stats(time_collector)
  end

  defp print_stats(time_collector) do
    %{locked: locked, unlocked: unlocked} =
      Agent.get(time_collector, & &1)
      |> Enum.reject(fn {key, _} -> key == :start end)
      |> Enum.sort_by(fn {_key, time} -> time end)
      |> Enum.group_by(fn {key, _} -> key end, fn {_key, time} -> time end)

    unlocked = Enum.drop(unlocked, -1)
    locked = Enum.drop(locked, 1)

    times =
      Enum.zip(unlocked, locked)
      |> Enum.map(fn {unlocked, locked} ->
        :erlang.convert_time_unit(locked - unlocked, :perf_counter, :microsecond)
      end)

    total_time = Enum.sum(times)
    total_locks = length(times)

    avg_time = div(total_time, total_locks)
    sorted_times = Enum.sort(times)
    min_time = hd(sorted_times)
    max_time = List.last(sorted_times)

    median_time =
      if rem(total_locks, 2) == 1 do
        Enum.at(sorted_times, div(total_locks, 2))
      else
        mid1 = Enum.at(sorted_times, div(total_locks, 2) - 1)
        mid2 = Enum.at(sorted_times, div(total_locks, 2))
        (mid1 + mid2) / 2
      end

    p99_index = max(0, min(total_locks - 1, trunc(Float.ceil(total_locks * 0.99)) - 1))
    p99_time = Enum.at(sorted_times, p99_index)

    IO.puts("""
    total locks: #{total_locks + 1}, \
    avg: #{avg_time} us, \
    min: #{min_time} us, \
    median: #{median_time} us, \
    max: #{max_time} us, \
    p99: #{p99_time} us
    """)
  end

  defp start_nodes(_ctx) do
    {:ok, _} = Node.start(:"test_origin_#{:os.getpid()}@localhost", :shortnames)
    on_exit(&Node.stop/0)

    task_sups =
      for _ <- 1..4 do
        node = TestHelper.start_node()

        :erpc.call(node, :code, :load_binary, [
          RemoteHelpers,
          ~c"#{__ENV__.file}",
          unquote(helpers_bytecode)
        ])

        :erpc.call(node, RemoteHelpers, :start_task_supervisor, [])
      end

    %{remote_task_sups: task_sups}
  end
end
