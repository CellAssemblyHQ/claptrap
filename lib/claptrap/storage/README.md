# Storage

A key-addressed blob store for opaque binary data. Storage is
where bytes go that don't fit relational tables — extracted
page bodies, cached feed responses, generated output files, and
similar payloads. Structured records belong in `Claptrap.Catalog`;
bytes belong here.

The split between catalog and storage is deliberate. The
catalog uses Ecto, foreign keys, and migrations, which are the
wrong tools for opaque blobs. The storage layer uses none of
those — just a key, a stream of bytes, and a pluggable backend.

## Architecture

```
Caller
  │  Claptrap.Storage.write/read/delete/list/exists?
  ▼
Claptrap.Storage         ← key validation, config lookup
  │  (in ../storage.ex)
  ▼
Claptrap.Storage.Adapter ← behaviour
  │
  ▼
Backend module           ← e.g. Backends.Local
  │
  ▼
Underlying medium        ← filesystem, S3, etc.
```

`Claptrap.Storage` itself does not persist anything. It
validates the key, resolves the backend from application
config, and delegates. This keeps the public API stable as
backends change.

`backends/` currently contains only `local.ex`, a
filesystem-backed adapter suitable for single-node deployments.

## Backend selection

The active backend is chosen from application config:

```elixir
config :claptrap, Claptrap.Storage,
  backend: Claptrap.Storage.Backends.Local,
  root_dir: "priv/storage"
```

The `:backend` key picks the adapter module. Every other key
goes into a `config` map that the facade hands to the adapter
on each call. Each backend therefore defines its own
configuration shape without changes to the public API — a
future S3 backend would just require different keys.

## Key format

Keys must match `[a-zA-Z0-9][a-zA-Z0-9._-]*`. That excludes
path separators, leading dots, whitespace, and null bytes.
Validation happens in the facade before any backend call, so
adapters never see malformed or traversal-prone keys. Invalid
keys raise `ArgumentError` rather than returning a tagged error
— malformed keys are programmer errors and should fail loudly.

The local backend uses `Path.safe_relative/1` as a second line
of defense, rejecting any resolved path that would escape the
configured `:root_dir`.

## Streaming

The behaviour is stream-oriented end to end. `write/2` accepts
any `Enumerable` of iodata chunks; backends consume
incrementally so large payloads never need to live in memory.
`read/1` returns `{:ok, Enumerable.t()}` — a lazy stream the
caller can consume chunk by chunk.

The local backend reads in 64 KiB chunks via
`Stream.resource/3`, opening the file lazily on first
consumption and closing it when the stream halts. Writes use
`IO.binwrite/2` per chunk against an open file handle.

## Error contract

All callbacks return tagged tuples on failure rather than
raising. Backends should use atoms for common cases (e.g.,
`:not_found`) so callers can pattern-match without depending on
a backend's specific error reasons. The local backend
translates `:enoent` to `:not_found` so callers don't need to
know about POSIX error names.

## Adding a backend

Create a module under `Claptrap.Storage.Backends`, add
`@behaviour Claptrap.Storage.Adapter`, implement all five
callbacks (`write`, `read`, `delete`, `list`, `exists?`), and
point the `:backend` config key at it. The behaviour
documentation in `adapter.ex` describes the contract in detail.

## Notes

- `list/1` in the local backend is non-recursive: it returns
  top-level entries under `:root_dir` whose names start with
  the given prefix, sorted alphabetically.
- The empty string is a valid prefix for `list/1` (meaning
  "list everything") but not a valid key.
