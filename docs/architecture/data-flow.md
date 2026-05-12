# Data flow

The Claptrap is, in spirit, a series of orchestrated ETL jobs. Consumers pull
and adapt entries from sources, Producers publish entries to sinks, and the
catalog keeps track of every entry flowing through the system. Subsystems are
generally isolated from one another, and the data between them is all the state
they need to perform their responsiblities. 

```
  External Sources                    External Sinks
         |                                    ^
+--------v----------+              +----------|----------+
|     Consumer      |              |      Producer       |
+-------------------+              +----------^----------+
         |                                    |
+--------v------------------------------------------------+
|                      Catalog                            |
|                    (PostgreSQL)                         |
|   sources, entries, artifacts, subscriptions, sinks     |
+---------------------------------------------------------+
                          |
                  +-------v------+
                  |      API     |
                  +--------------+
```

1. **Source.** An external or upstream provider of content to consume into
   Claptrap. Often, this is a collection of items like RSS feeds, Youtube
   channels, etc.
2. **Consumer.** A worker process that consumes entries from a source using
   type-specific adapters.
3. **Catalog / Entry.** Claptrap's architectural center of gravity; the
   central registry. Connects to PostgreSQL to manage all resource
   definitions -- namely, entries.
4. **Producer.** A worker process that publishes entries to a sink using
   type-specific adapters.
5. **Sink.** An external or downstream destination for entries. Again, this
   is a collection of items like RSS feeds, webhooks, etc.

## Catalog

The Catalog is the authoritative owner of all persisted resource
definitions and the boundary through which other subsystems interact
with the database.

### Owned resources

- **Sources** — configured upstream content origins
- **Entries** — normalized content records discovered from sources
- **Sinks** — configured delivery targets
- **Subscriptions** — tag-based routing rules that determine which
  sinks receive entries

The Catalog does not perform content fetching or delivery itself. It
defines the persisted state that allows the consumer and producer
subsystems to do that work.

## Consumers and Produceres

### Process model

Both Consumers and Producers run one worker per source. Each source/sink gets
its own GenServer process, providing isolated state, isolated failures,
independent scheduling, and natural backpressure.

### Consumer Coordinator

The consumer coordinator is responsible for bootstrapping workers for all
enabled sources at init and periodically reconciling running workers against
the Catalog. Workers self-schedule their own poll cycles and the coordinator
spawns new workers as sources are added.

### Producer Router

A single GenServer that owns routing and dispatch:

1. **Subscribe** — on init, subscribe to PubSub topic `entries:new`
2. **Route** — when `{:entries_ingested, source_id, entries}`
   arrives, query the Catalog for matching subscriptions using
   tag-based overlap (ANY semantics)
3. **Dispatch** — send `{:deliver, entries}` to each matching
   `Producer.Worker`

## PubSub

Claptrap uses Phoenix.PubSub as the internal event bus between
consumers, producers, and the extractor subsystem. The consumer
subsystem publishes on `entries:new` when it has just ingested a
batch, and both the producer router and the extractor router
subscribe to that topic independently. Neither subsystem knows about
the other.

See the [PubSub reference](pubsub.md) for the full set of topics and
message shapes, and the [extractor architecture](extractor.md) for
how the extractor subsystem turns those events into stored
artifacts.


## Entry ordering

Entries are delivered in consumption order, using `inserted_at` with
microsecond precision. The Router preserves ordering when
dispatching.
