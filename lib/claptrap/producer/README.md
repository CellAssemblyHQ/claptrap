# Producer

The producer delivers ingested entries to sinks. It listens for
new entries on PubSub, matches them against subscriptions, and
hands each match to a per-sink worker that either pushes the
entry to an external service or materializes it for on-demand
retrieval (e.g., generating an RSS feed body to serve later).

The push/pull split is the central design choice. Both modes
share the same worker, supervisor, and routing logic, and
differ only in which adapter callback runs and where the result
goes — an external HTTP call for push, ETS for pull.

## Architecture

```
PubSub "entries:new"
  │
  ▼
Router ──▶ subscriptions_for_tags() ──▶ group by sink
  │
  ├──▶ Worker (pull)  ── Adapter.materialize() ──▶ ETS
  └──▶ Worker (push)  ── Adapter.push() ─────────▶ External API
```

The supervisor uses `:rest_for_one` with the worker supervisor
first and the router second. The router holds references to
worker names, so it must restart whenever workers do. The ETS
table `:claptrap_rss_feeds` is owned by the *supervisor process
itself*, not by a worker, so it survives both router and worker
crashes — without this, a pull-mode worker crash would wipe the
cached feed body.

On startup the router bootstraps one worker per enabled sink.
Pull-mode workers immediately materialize an initial (empty)
feed so HTTP consumers don't 404 before the first entry
arrives.

## Tag-based routing

Routing matches entry tags against subscription tags using
`MapSet.disjoint?/2`. If the two sets are *not* disjoint, the
entry is delivered to the subscription's sink:

```
Entry (tags: ["tech", "elixir"])
  │
  ▼
Subscription A (tags: ["elixir"], sink_id: 1)  ← match
Subscription B (tags: ["rust"],   sink_id: 2)  ← no match
```

A single entry can fan out to multiple sinks if it matches
multiple subscriptions. The router groups by sink before
dispatch so each worker receives one batched call per event,
not one call per matching subscription.

## Adapter behaviour

`Claptrap.Producer.Adapter` defines the contract for sink
types:

```elixir
@callback mode() :: :push | :pull
@callback push(Sink.t(), [Entry.t()]) :: :ok | {:error, term()}
@callback materialize(Sink.t(), [Entry.t()]) ::
            :ok | {:error, term()}
@callback validate_config(map()) :: :ok | {:error, String.t()}
```

`adapters/` currently contains `rss_feed.ex` (the only sink
adapter, pull-mode, generates RSS 2.0 XML into ETS) and
`rss_uri.ex` (a URI-validation helper used by `rss_feed`).
Adding a sink type means implementing the behaviour and adding
a clause to `Worker.adapter_for_type/1`.

RSS sinks require `config["description"]`, `config["link"]`
(absolute URL with scheme and host), and optionally
`config["max_entries"]`. `validate_config/1` enforces these at
sink-create time.

Pull-mode `materialize/2` ignores the entries passed by the
worker and re-reads the full sink-relevant set from the catalog
via `Catalog.entries_for_sink/2`. This keeps the cached feed
body authoritative against the database — there is no append
path that could drift out of sync.

## Retries and telemetry

Worker delivery uses exponential backoff with jitter, capped at
30 seconds and 5 attempts:

```
delay_ms = min(500 * 2^attempt + jitter, 30_000)
```

Failed batches are dropped after exhausting retries — there is
no dead-letter queue. The expectation is that pull-mode sinks
will catch up on the next event, and push-mode failures are
reported via telemetry for external monitoring.

Workers emit telemetry events under `[:claptrap, :producer, :*]`:

- `[:claptrap, :producer, :delivery]` — `sink_id`,
  `entry_count`, `status`
- `[:claptrap, :producer, :retry]` — `sink_id`, `attempt`,
  `delay`

## Notes

- The ETS table is created with `read_concurrency: true` and
  `:public` access so HTTP handlers can read directly without
  going through the worker.
- The 30s/5-attempt retry budget is shared with the consumer
  by convention — both subsystems use the same shape so backoff
  behaviour is uniform across the pipeline.
