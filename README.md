# FastGlobalLock

A `:global`-based `set_lock`/`del_lock` with fast locks under contention through process cooperation.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `fast_global_lock` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:fast_global_lock, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/fast_global_lock>.
