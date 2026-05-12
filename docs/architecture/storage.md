# Storage

Storage is Claptrap's blob layer. It exists for opaque binary data that
does not fit naturally into a relational table, such as cached feed
bodies, generated output files, or future artifact payloads that are
too large to inline into a Postgres row.

Storage is deliberately separate from the Catalog. The Catalog owns
structured records and their relationships. Storage owns bytes, keyed
by a flat string. Anything that needs both a structured row and a blob
should record the row in the Catalog and reference the blob by key.

## Public API

`Claptrap.Storage` exposes a small surface for callers. There are five
operations.

| Function | Purpose |
| --- | --- |
| `write(key, data)` | Store an iodata stream under `key` |
| `read(key)` | Return `{:ok, stream}` for the stored bytes, or `{:error, :not_found}` |
| `delete(key)` | Remove the blob, or return `{:error, :not_found}` |
| `list(prefix)` | List keys that start with `prefix`, sorted alphabetically |
| `exists?(key)` | Return `{:ok, boolean}` for whether the blob exists |

All five functions validate the key shape before touching the backend.
Writes accept an enumerable of iodata chunks so that callers can stream
large payloads without holding the full body in memory. Reads return a
lazy stream, also chunked, so that downstream code can iterate
incrementally.

A typical usage looks like this.

```elixir
:ok = Claptrap.Storage.write("feed-cache.xml", [xml_body])

{:ok, stream} = Claptrap.Storage.read("feed-cache.xml")
body = Enum.join(stream)

{:ok, keys} = Claptrap.Storage.list("feed-")
:ok = Claptrap.Storage.delete("feed-cache.xml")
```

## Key format

Keys are flat, non-empty strings that match the pattern
`[a-zA-Z0-9][a-zA-Z0-9._-]*`. A key must start with an alphanumeric
character, and may then contain alphanumerics, dots, underscores, and
hyphens. Everything else is rejected with an `ArgumentError` before the
backend is ever called.

This shape is intentional. It rules out a number of failure modes at
the API boundary rather than at the backend. Empty strings, absolute
paths, leading dots, path separators, whitespace, and null bytes are
all rejected. The local filesystem backend uses `Path.safe_relative/1`
as a second line of defense, but the public API never lets such keys
through in the first place.

The `prefix` argument of `list/1` follows the same pattern, with the
single exception that an empty prefix is allowed and means "list
everything".

## Backend delegation

`Claptrap.Storage` does not implement persistence. Every call is
forwarded to a backend module that implements the
`Claptrap.Storage.Adapter` behaviour. The backend is chosen at runtime
from the application configuration.

```elixir
config :claptrap, Claptrap.Storage,
  backend: Claptrap.Storage.Backends.Local,
  root_dir: "priv/storage"
```

The `:backend` key picks the adapter module. Every other key in the
same block is collected into a map and handed to the adapter as its
`config` argument on each call. This keeps the public API
backend-agnostic and lets each adapter define its own configuration
shape without changing `Claptrap.Storage` itself.

```
   Caller
     |
     v
+---------------------+
| Claptrap.Storage    |  validates key, picks backend
+----------+----------+
           |
           v
+---------------------+
| Storage.Adapter     |  behaviour, five callbacks
| (Local, S3, ...)    |
+---------------------+
```

## Adapter behaviour

`Claptrap.Storage.Adapter` defines five callbacks covering the full
blob lifecycle.

| Callback | Returns |
| --- | --- |
| `write(key, data, config)` | `:ok` or `{:error, reason}` |
| `read(key, config)` | `{:ok, Enumerable.t()}` or `{:error, reason}` |
| `delete(key, config)` | `:ok` or `{:error, reason}` |
| `list(prefix, config)` | `{:ok, [String.t()]}` or `{:error, reason}` |
| `exists?(key, config)` | `{:ok, boolean}` or `{:error, reason}` |

Callbacks return tagged tuples on failure rather than raising. The
`reason` term is backend-specific, but adapters are expected to use
atoms where possible, in particular `:not_found` for missing keys, so
that callers can pattern match on common cases.

The `write/3` callback receives `data` as `Enumerable.t()` of iodata
chunks, and backends are required to consume that enumerable
incrementally rather than collecting it into a single binary. The
`read/2` callback returns an `Enumerable.t()`, which should be a lazy
stream so that callers can process bytes chunk by chunk.

## Local backend

`Claptrap.Storage.Backends.Local` is the default backend and is
appropriate for single-node deployments. It maps each storage key to a
file inside a configurable root directory. It needs a single
configuration key, `:root_dir`, which may be absolute or relative to
the project root.

Writes create parent directories on demand using `File.mkdir_p!/1`, so
nested keys containing `/` separators work transparently. Reads return
a lazy stream that emits 64 KiB chunks, opens the file lazily when the
stream is first consumed, and closes it automatically when the stream
terminates. The read path verifies that the file can be opened before
returning the stream, so callers get an immediate `{:error, :not_found}`
for missing keys rather than an exception on first iteration.

The backend resolves every key through `Path.safe_relative/1` before
touching the filesystem. Any key that would escape the root directory
raises an `ArgumentError`, which means that even if the public key
validator is bypassed the backend will refuse to read or write files
outside the configured root.

`list/2` returns the top-level entries in the root directory that
match the given prefix. It does not recurse into subdirectories.
Results are sorted alphabetically.

## Relationship to artifacts

Artifacts today inline their `content` directly into the Postgres row,
so the storage subsystem is not on the critical path of extraction.
The two subsystems are designed to compose, however. A future adapter
that produces large payloads, for example PDF, can write the body to
storage under a key derived from `entry_id` and `format`, and record
the key in the artifact's `metadata` field. The artifact schema does
not require `content` to be set, precisely so that this kind of
out-of-band storage is possible without a migration.

## Adding a new backend

To add a backend, create a module under `Claptrap.Storage.Backends`,
add `@behaviour Claptrap.Storage.Adapter`, implement all five
callbacks, and set the new module as `:backend` in the application
configuration. The backend will receive its own configuration shape as
the `config` map on every call, so it can require whatever keys it
needs without affecting any caller of `Claptrap.Storage`.
