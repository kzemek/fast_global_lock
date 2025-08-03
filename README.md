# FastGlobalLock

[![CI](https://github.com/kzemek/fast_global_lock/actions/workflows/ci.yml/badge.svg)](https://github.com/kzemek/fast_global_lock/actions/workflows/ci.yml)
[![Module Version](https://img.shields.io/hexpm/v/fast_global_lock.svg)](https://hex.pm/packages/fast_global_lock)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/fast_global_lock/)
[![License](https://img.shields.io/hexpm/l/fast_global_lock.svg)](https://github.com/kzemek/fast_global_lock/blob/master/LICENSE)

`FastGlobalLock` is a library that provides several features on top of [`:global`] lock mechanism.

- Adds process cooperation to minimize time from `lock/2` to the next `unlock/2` under contention.
- Improves fairness, with processes likely to acquire locks in the order in which they called `lock/2` (FIFO).
- Provides [`:global`]-compatibility API, while also defining a native API better aligned with its locking semantics.

## Key differences from [`:global`]

`FastGlobalLock`, being based on [`:global`], has very similar semantics.
There are several key differences to be aware of:

- When a process acquires a lock through `FastGlobalLock`, the actual lock in [`:global`] is owned by a separate linked process.

- [`:global`] with `Retries>0` relies solely on polling with an increasing, random sleep of up to 8 seconds.

  - To minimize time between locks, `FastGlobalLock` uses inter-process communication to notify waiting peers that the lock can be acquired.

- Any process can acquire the lock when calling [`:global.set_lock/3`]; later processes have a slightly better chance due to more frequent initial polling.

  - `FastGlobalLock` orders pending locks and wakes up waiting processes in FIFO order.  
    This is not a guarantee!
    Other processes can still acquire the lock, if their attempt falls between `unlock` and handover, although it's an infrequent edge case.

- [`:global.set_lock/3`] allows multiple processes to acquire the same lock if they use the same `LockRequesterId`.

  - This is unsupported in `FastGlobalLock`.
    The `LockRequesterId` part of the `id` is ignored in its [`:global`] compatibility API.

- [`:global`] only acquires one lock no matter the number of `set_lock` calls.

  - `FastGlobalLock` supports lock nesting in its native API.

- [`:global`] takes a `Retries` argument, and sleeps for a random (increasing) time between lock attempts.

  - `FastGlobalLock` uses a millisecond `timeout` instead.
    The compatibility API translates `retries` to the (average) timeout that [`:global`] would sleep before giving up.

- [`:global`] gives an option to release the lock only on select nodes.
  - `FastGlobalLock` always releases the lock everywhere it was acquired.

## Correctness

Correctness of `FastGlobalLock` is transitive from [`:global`].

The lock holder process only calls functions that can time out.
If any mechanism fails, it falls back to polling [`:global.set_lock/3`].

In case of a bug in `FastGlobalLock` that would lead to lock-holder crash, the lock will be released, and the process that requested the lock will receive an exit signal.

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
