# Extractor

The extractor subsystem turns entry URLs into stored artifacts. When the
consumer subsystem discovers a new piece of content, all the catalog
knows is the metadata that the source provider exposed. The extractor
is what goes out to the open web, fetches the underlying document, and
records a normalized rendering of it as an artifact attached to the
entry.

The extractor is intentionally decoupled from the consumer. It does not
share a process with consumer workers, it does not block ingestion, and
it does not need to know how an entry was discovered. It only needs the
entry's URL.

## Shape of the subsystem

The extractor has three moving parts and a supervised pool of
short-lived tasks.

```
              entries:new (PubSub)
                       |
                       v
            +----------+-----------+
            |   Extractor.Router   |       (GenServer)
            +----------+-----------+
                       |
              starts one task per entry
                       |
                       v
        +------------------------------+
        |  Extractor.TaskSupervisor    |   (Task.Supervisor)
        |                              |
        |   Task: Pipeline.extract_    |
        |         and_store(entry,     |
        |         formats, config)     |
        +---------------+--------------+
                        |
                        v
               +--------+--------+
               | Adapter.extract |       (per format)
               +--------+--------+
                        |
                        v
              Catalog.create_artifact
```

The router is the event boundary. The task supervisor isolates one
entry's extraction work from every other entry's work. The pipeline
holds the per-entry, per-format logic. The adapter is the only piece
that talks to an external service.

## Router

`Claptrap.Extractor.Router` is a single GenServer that subscribes to
the internal `entries:new` PubSub topic at startup. It receives
messages of the shape `{:entries_ingested, source_id, entries}` from
the consumer subsystem.

For each message the router filters out entries whose URL is missing
or empty, then starts one supervised task per remaining entry under
`Claptrap.Extractor.TaskSupervisor`. The router does no extraction
work itself. It is meant to stay responsive even when external
providers are slow, so all of the latency lives inside the supervised
tasks rather than inside the router's mailbox.

When the application is configured with no extraction formats, the
router still subscribes and still receives events, but it logs and
drops them. This makes extraction a runtime concern rather than a
deploy-time concern. Turning extraction off does not require removing
the router from the supervision tree.

## Pipeline

`Claptrap.Extractor.Pipeline.extract_and_store/3` is the per-entry
worker function. It receives the entry, the list of formats to
produce, and a configuration map. For every requested format it looks
up the configured adapter, calls it with retry and exponential
backoff, and upserts the result as an artifact through the catalog.

The pipeline is deliberately resilient at the batch level. If no
adapter is configured for a requested format it logs a warning and
moves on to the next format. If extraction for one format fails after
all retries it logs an error and moves on. If persisting one artifact
fails it logs an error and moves on. The intent is that one failing
format never blocks the others from succeeding for the same entry,
and one failing entry never blocks the others in the same batch.

### Retry behavior

Adapter calls are retried up to `:max_attempts` times, which defaults
to five. Between attempts the pipeline sleeps for a duration computed
as exponential backoff with jitter, bounded by `:max_backoff_ms`. The
formula in code is

```
delay_ms =
  min(
    base_backoff_ms * 2^(attempt - 1) + random(1..200),
    max_backoff_ms
  )
```

with `:base_backoff_ms` defaulting to 500 and `:max_backoff_ms`
defaulting to 30 seconds. Sleeping happens inside the supervised
task, so the router's mailbox is never blocked by a slow remote
service.

### Persistence

Successful extraction results are written through
`Claptrap.Catalog.create_artifact/1`, which performs an upsert keyed
on `(entry_id, format)`. Re-running extraction for the same entry and
format therefore replaces the previous artifact rather than creating a
new one. See the [artifacts page](../catalog/artifacts.md) for the
full schema.

## Adapter behaviour

`Claptrap.Extractor.Adapter` is the behaviour that every extractor
provider must implement. It has two callbacks. `extract/3` takes a
URL, a format string, and an options map, and returns either
`{:ok, %{content: ..., content_type: ..., metadata: ...}}` or
`{:error, reason}`. `supported_formats/0` returns the list of formats
the adapter can produce.

Adapters are responsible for the provider-specific request and
response handling. They are not responsible for retries, for
persistence, or for deciding whether a given URL should be processed.
The pipeline handles all of that.

A minimal adapter implementation looks like this.

```elixir
defmodule MyAdapter do
  @behaviour Claptrap.Extractor.Adapter

  @impl true
  def supported_formats, do: ["markdown"]

  @impl true
  def extract(url, "markdown", _opts) do
    # fetch and transform...
    {:ok, %{content: body, content_type: "text/markdown", metadata: %{}}}
  end
end
```

## Firecrawl adapter

`Claptrap.Extractor.Adapters.Firecrawl` is the only adapter shipped
today. It posts to Firecrawl's `/v1/scrape` endpoint with the entry
URL and the requested format, and translates the response into the
adapter contract. It supports the `markdown` and `html` formats, and
sets the corresponding content types on the resulting artifact.

The adapter reads its credentials from `:claptrap, :firecrawl`. The
`:api_key` is sent as a Bearer token. The `:base_url` defaults to
`https://api.firecrawl.dev` but may be overridden for testing or
self-hosted Firecrawl deployments. See the
[configuration reference](../configuration.md) for the full list of
keys.

The adapter treats any non-200 response as an error and lets the
pipeline retry. A 200 response with no extracted content for the
requested format also returns an error so that the pipeline retries
rather than silently writing an empty artifact.

## Supervision

`Claptrap.Extractor.Supervisor` is the supervision root for the whole
subsystem. It supervises the task supervisor and the router with a
`:rest_for_one` strategy and starts them in that order. The router
depends on the task supervisor existing, so if the task supervisor
crashes the router is restarted afterwards to drop any stale
references it might have been holding.

Individual extraction tasks live and die independently. A crash inside
one task does not affect the router, the task supervisor, or any
other task.

## When extraction is disabled

If `:formats` in the `:claptrap, :extraction` config is empty, the
router still starts and still subscribes to PubSub, but it logs every
incoming batch and discards it. This is the supported way to turn
extraction off without removing the subsystem from the supervision
tree, and it is the default behavior any time `FIRECRAWL_API_KEY` is
unset in production.
