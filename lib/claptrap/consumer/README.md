# Consumer

The consumer fetches content from external sources, normalizes
it into entries, persists them through `Claptrap.Catalog`, and
broadcasts the new entries on PubSub for downstream subsystems
(extractor, producer) to pick up.

It is a polling pipeline. Each enabled source gets its own
long-running worker that re-polls on a schedule. A separate
coordinator keeps the set of workers in sync with the set of
enabled sources in the database — adding or disabling a source
eventually adds or removes the corresponding worker without
requiring a restart.

## Architecture

```
           Coordinator
               │
               │ every 30s: ensure worker per enabled source
               ▼
Source (DB) ──▶ Worker ──▶ Adapter.fetch() ──▶ External feed
                  │
                  ├──▶ Catalog.create_entry()
                  └──▶ PubSub.broadcast("entries:new")
```

The supervisor uses `:rest_for_one` with the worker supervisor
first and the coordinator second. If the worker supervisor
crashes, the coordinator restarts with it and re-bootstraps
workers. If only the coordinator crashes, existing workers keep
polling uninterrupted.

Workers register in `Claptrap.Registry` under
`{:source_worker, source_id}`. This prevents two workers from
being started for the same source and lets the coordinator look
up existing workers cheaply.

## Adapter behaviour

`Claptrap.Consumer.Adapter` defines the contract for source
types:

```elixir
@callback mode() :: :pull | :push
@callback fetch(Source.t()) :: {:ok, [map()]} | {:error, term()}
@callback ingest(term(), Source.t()) ::
            {:ok, [map()]} | {:error, term()}
@callback validate_config(map()) :: :ok | {:error, String.t()}
```

Only `:pull` mode is implemented today. `adapters/rss.ex`
handles both RSS and Atom feeds. The worker resolves the adapter
from the source's `type` field at init time via
`Worker.adapter_for_source_type!/1`. Adding a new source type
means implementing the behaviour and adding a clause to that
function.

## Worker lifecycle

Each worker follows a three-phase loop:

1. **Init.** Load the source, resolve the adapter, validate
   config, schedule the first poll.
2. **Poll.** Call `adapter.fetch(source)`, map results through
   `Catalog.create_entry/1`, broadcast newly-inserted entries,
   reset the retry count, schedule the next poll.
3. **Retry.** On transient errors, back off and try again.

The poll/retry distinction matters: a failed poll does not wait
for the normal interval to come around again, it retries faster
via the backoff schedule. After exhausting retries the worker
drops back into the normal poll cadence.

Backoff is exponential with jitter, capped at 30 seconds and
5 attempts:

```
delay_ms = min(500 * 2^attempt + jitter, 30_000)
```

## Timer discipline

Scheduled polls use `Process.send_after/3` with a `make_ref()`
token. The worker only acts on the most recently issued token,
so reschedules (e.g., during retry) don't produce double-polls
if an older timer fires later.

The RSS adapter disables `Req`'s internal retry layer because
retries belong to the worker — stacking two retry loops would
multiply attempts and make backoff incoherent.

## Notes

- The PubSub message shape is `{:entries_ingested, source_id,
  entries}` on `Claptrap.PubSub.topic_entries_new/0` (the
  literal topic is `"entries:new"`).
- Only entries that actually persisted (got an `id` back from
  the catalog) are included in the broadcast.
- The coordinator's 30-second sweep is the lower bound on how
  quickly a newly-enabled source starts polling.
