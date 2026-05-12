# Extractor

The extractor turns newly-ingested entries into *artifacts* —
derived representations of the entry's content in formats like
markdown, HTML, or PDF. An entry is mostly metadata (title, URL,
tags); the artifact is the readable body downstream consumers
actually want. Splitting them lets ingest and the API stay fast
while "fetch the page behind this URL and parse it" runs in the
background.

The subsystem is event-driven and stateless. It does not poll,
hold its own queue, or expose an API. It subscribes to PubSub,
fans out one task per entry, and writes results through
`Claptrap.Catalog`. Failed extractions are logged and dropped;
a re-run will retry them.

## Architecture

```
PubSub "entries:new"
  │  {:entries_ingested, source_id, entries}
  ▼
Router  ──▶ filter entries with URLs
  │
  │  one Task per entry, under TaskSupervisor
  ▼
Pipeline  ──▶ for each configured format:
  │            adapter.extract(url, format, opts)   (with retries)
  │            Catalog.create_artifact(...)         (upsert)
  ▼
Catalog (Artifact)
```

`Router` is a thin GenServer that receives PubSub messages and
dispatches work. `Pipeline` is a plain module that runs inside
each spawned task — no process of its own. Adapters under
`adapters/` hold the only provider-specific logic. The same
three-layer split (event boundary, work logic, provider
integration) is used by `Claptrap.Consumer` and
`Claptrap.Producer`.

## Supervision

`Claptrap.Extractor.Supervisor` runs two children under
`:rest_for_one`:

1. `Extractor.TaskSupervisor` — owns the per-entry tasks.
2. `Extractor.Router` — subscribes to PubSub and spawns tasks.

The ordering matters because the router holds a reference to
the task supervisor's name. `:rest_for_one` ensures that if the
task supervisor dies, the router is restarted with it and never
ends up holding a stale reference.

Tasks are intentionally unlinked from anything that cares about
their result. A crashed task takes its artifact with it and
logs; the next ingest of that entry will try again.

## Adapters

`Claptrap.Extractor.Adapter` is a two-callback behaviour:

```elixir
@callback extract(url :: String.t(), format :: String.t(),
                  opts :: map()) ::
            {:ok, %{content: binary(),
                    content_type: String.t(),
                    metadata: map()}} | {:error, term()}

@callback supported_formats() :: [String.t()]
```

Adapters do not retry, do not write to the catalog, and do not
emit pipeline-level logs — the pipeline handles all of that.
To add a provider: create a module under `adapters/`, implement
the two callbacks, and register it in the `:extraction`
application config.

## Configuration

The router reads `Application.get_env(:claptrap, :extraction)`
at init. Two keys matter:

- `:formats` — list of formats to extract per entry, e.g.
  `["markdown", "html"]`.
- `:adapters` — `%{format => AdapterModule}`.

If `:formats` is empty (the default when extraction isn't
wired up), the router runs but no-ops every event. This is what
makes extraction safely optional.

Retry tuning lives in the same config map: `:max_attempts`
(default 5), `:base_backoff_ms` (500), `:max_backoff_ms`
(30_000). Any other keys are forwarded to adapters via `opts`,
which is how API keys get through.

## Per-format independence

Within a task, each configured format runs independently. If
markdown extraction fails for entry X but HTML succeeds, you
get the HTML artifact and a logged error for markdown. The
same is true for persistence errors. The pipeline deliberately
never aborts an entry on first failure — formats fail for
unrelated reasons and there's no value in losing successful
results.

## Retries

Adapter calls retry with exponential backoff and jitter:

```
delay_ms = min(base * 2^(attempt - 1) + random(1..200), max)
```

Retries are synchronous (`Process.sleep/1`) within the task.
This is fine because tasks are isolated and nothing waits on
them. After `:max_attempts` failures, that format is dropped
for that entry.

## Persistence and idempotency

Results go through `Catalog.create_artifact/1`, which upserts
on the unique constraint `[:entry_id, :format]`. Re-running
extraction — restart, manual trigger, duplicate event —
replaces the previous artifact rather than creating duplicates.
The subsystem holds no deduplication state of its own.

## Operational notes

- The router never blocks on extraction work, so a hung
  provider cannot back up the PubSub mailbox.
- Entries with `nil` or empty `url` are filtered out before
  task dispatch.
- There is no rate limiting between tasks. A large batch
  produces one concurrent task per entry; if that becomes a
  problem, throttle in the router's dispatch loop, not the
  pipeline.
- Log lines are tagged with the module name and include the
  entry ID where applicable.
