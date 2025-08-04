# FastGlobalLock

[![CI](https://github.com/kzemek/fast_global_lock/actions/workflows/ci.yml/badge.svg)](https://github.com/kzemek/fast_global_lock/actions/workflows/ci.yml)
[![Module Version](https://img.shields.io/hexpm/v/fast_global_lock.svg)](https://hex.pm/packages/fast_global_lock)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/fast_global_lock/)
[![License](https://img.shields.io/hexpm/l/fast_global_lock.svg)](https://github.com/kzemek/fast_global_lock/blob/master/LICENSE)

`FastGlobalLock` is a library that builds on top of [`:global`] to minimize the time between locks under contention and to provide a best-effort FIFO locking mechanism.

## Key differences from `:global`

Because `FastGlobalLock` builds on `:global`, its lock semantics are similar.
There are several key differences to be aware of:

| `:global`                                                                                         | `FastGlobalLock`                                                                   |
| ------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Relies solely on polling with an increasing, random sleep of up to 8 seconds.                     | Uses inter-process communication to minimize time between locks.                   |
| Which process acquires a lock under contention is fully random.                                   | Orders pending locks and wakes waiting processes in FIFO order.                    |
| Multiple processes can acquire the same lock if they use the same `LockRequesterId`.              | Only one process can hold a lock for a key on any given ndoe.                      |
| Acquires at most one lock no matter how many [`set_lock/2`](`:global.set_lock/2`) calls are made. | Supports lock nesting in its native API.                                           |
| Can release the lock only on selected nodes.                                                      | Always releases the lock everywhere it was acquired.                               |
| Can extend the lock to more nodes.                                                                | If a lock for a `key` is already held, it can only be nested on the same node set. |
| Takes a `Retries` argument and sleeps for a random time between attempts.                         | Takes a millisecond `timeout`.                                                     |
| The process calling [`set_lock/2`](`:global.set_lock/2`) is monitored for liveness.               | A separate linked process is spawned per `lock/2` and monitored for liveness.      |

## Important notes

### Increased CPU usage compared with `:global`

`FastGlobalLock` shortens the wall-clock time between locks, but it achieves this by using **more** CPU time.
A coordination layer on top of `:global` inevitably adds some processing overhead.

One particularly bad CPU scenario occurs when there is heavy contention for a key, with some processes locking on a single node while others lock cluster-wide.
To determine if and where the lock is already present, `FastGlobalLock` probes the `:nodes` one at a time.
It continues this loop without sleeping until it either acquires the lock or discovers that the key is locked elsewhere.

This design is efficient when all requests target roughly the same set of nodes.
However, if one process tries to lock 100 nodes while the lock is already held on just one of them, merely locating the lock can become expensive.

### Concurrent locks for disjoint node sets

Multiple concurrent locks (by different processes) can be acquired for the same key if they lock on disjoint `:nodes` sets.
If processes attempt to acquire locks for `:nodes` spanning multiple existing locks, the fairness mechanism is likely to be disturbed.
The fast locking mechanism still works in this scenario.

Note that multiple concurrent locks for the same key cannot be acquired by the same process.
`FastGlobalLock` will either nest the existing lock, or raise, depending on the `:on_nodes_mismatch` setting.
See `lock/2` for more information.

## Correctness

- `FastGlobalLock` inherits most of its correctness guarantees from `:global`.
- If any mechanism fails, it falls back to polling [`:global.set_lock/3`].
- While the lock-holder GenServer process is yet to acquire the lock, every callback either returns a timeout value or terminates the server altogether.
- Should a bug in `FastGlobalLock` cause the lock-holder to crash, the lock is released automatically by `:global`.
  The process that requested the lock will receive an exit signal through their link.

## Installation

The package can be installed by adding `fast_global_lock` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:fast_global_lock, "~> 0.0.1"}
  ]
end
```

[`:global`]: https://www.erlang.org/doc/apps/kernel/global.html
[`:global.set_lock/3`]: https://www.erlang.org/doc/apps/kernel/global.html#set_lock/3
