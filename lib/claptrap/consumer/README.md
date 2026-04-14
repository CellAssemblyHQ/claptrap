# Consumer

A supervised ingestion pipeline that fetches or receives content from
external sources, normalizes it into entries, persists them via
`Claptrap.Catalog`, and broadcasts new entries over PubSub for
downstream producers.

## Architecture

```
           Coordinator
               │
               │ every 30s: ensure worker per enabled source
               ▼
Source (DB) ──▶ Worker ──▶ Adapter.fetch()/Adapter.ingest()
                  │
                  ├──▶ Catalog.create_entry()
                  └──▶ PubSub.broadcast("entries:new")
```

## Supervisor tree

```
Consumer.Supervisor (:rest_for_one)
  │
  ├── WorkerSupervisor (DynamicSupervisor, :one_for_one)
  │     ├── Worker (source A)
  │     ├── Worker (source B)
  │     └── ...
  │
  └── Coordinator (GenServer)
```

The `:rest_for_one` strategy means if the `WorkerSupervisor`
crashes, the Coordinator also restarts. If only the Coordinator
crashes, existing workers keep running.

## Subdirectories

- **`adapters/`** — Concrete implementations of the
  `Claptrap.Consumer.Adapter` behaviour (RSS pull mode, IMAP push
  mode).

## Key concepts

The adapter behaviour defines the contract for source types:

```elixir
@callback mode() :: :pull | :push
@callback fetch(Source.t()) :: {:ok, [map()]} | {:error, term()}
@callback ingest(Source.t(), term()) :: {:ok, [map()]} | {:error, term()} | :ignore
@callback validate_config(map()) :: :ok | {:error, String.t()}
```

The worker resolves the adapter from the source's `type` field at init
time and branches by adapter mode.

Each worker follows a three-phase lifecycle:

1. **Init** — Loads the source from the DB, resolves the adapter,
   validates config, then:
   - for `:pull`: schedules the first poll
   - for `:push`: starts adapter-owned listener process
2. **Consume** — Depending on mode:
   - `:pull`: handles `:poll`/`:retry`, calls `adapter.fetch(source)`
   - `:push`: handles inbound messages, calls
     `adapter.ingest(source, message)`
3. **Retry (`:pull` only)** — On transient fetch errors, uses
   exponential backoff (`500ms × 2^attempt + jitter`, capped at 30s,
   max 5 retries). After exhausting retries, falls back to the normal
   poll interval.

## Notes

- Workers register in `Claptrap.Registry` under
  `{:source_worker, source_id}` to prevent duplicates and enable
  lookup.
- Timer messages use a `make_ref()` token — only the most
  recently scheduled timer is honored, preventing double-polls.
- The RSS adapter disables `Req` retries internally and handles
  retry logic at the worker level instead.
- Push adapters own listener lifecycle and should return `:ignore` from
  `ingest/2` for unrelated messages.
- Adding a new source type requires implementing the
  `Claptrap.Consumer.Adapter` behaviour and adding a clause to
  `Worker.adapter_for_source_type!/1`.
