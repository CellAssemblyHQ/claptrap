# PubSub

PubSub is the internal event bus that wires Claptrap's subsystems
together without coupling them at compile time. The consumer
subsystem broadcasts the fact that new entries exist, and any
subsystem interested in that fact subscribes. Neither side needs to
know about the other.

Under the hood this is `Phoenix.PubSub` running in-process. The
wrapper module `Claptrap.PubSub` exposes a small surface, owns the
topic names as functions, and is the only module that other code
should call.

## Why it exists

Claptrap is structured so that the consumer subsystem can run without
knowing whether anyone is producing or extracting, and so that the
producer and extractor subsystems can run without knowing how
entries were discovered. PubSub is the contract boundary that makes
that possible. The shape of the messages on each topic is the only
thing the subsystems agree on. Everything else, including process
identity, scheduling, and failure handling, stays private to each
subsystem.

## Topics

There are three topics in the system today. The wrapper exposes each
as a function so that callers never type the raw string and never
need to keep two copies of it in sync.

| Topic | Helper | Publisher | Subscribers |
| --- | --- | --- | --- |
| `entries:new` | `topic_entries_new/0` | `Consumer.Worker` | `Producer.Router`, `Extractor.Router` |
| `catalog:changed` | `topic_catalog_changed/0` | `Catalog.Server` | `Consumer.Coordinator`, `Producer.Router` |
| `extraction:complete` | `topic_extraction_complete/0` | `Extractor.Pipeline` | downstream consumers |

```
  Consumer.Worker
        |
        |  {:entries_ingested, source_id, entries}
        v
  entries:new --------------------+
        |                         |
        v                         v
  Producer.Router          Extractor.Router
                                  |
                                  v
                          Extractor.Pipeline
                                  |
                                  |  {:artifact_created, entry_id, format}
                                  v
                       extraction:complete

  Catalog.Server
        |
        |  {:catalog_changed, kind, id}
        v
  catalog:changed --------------+
        |                       |
        v                       v
  Consumer.Coordinator    Producer.Router
```

## Message contracts

The shape of each message is part of the public contract of its
topic. Changing a message shape is a coordinated change across every
publisher and subscriber. The shapes below are what the current code
sends.

### `entries:new`

The consumer subsystem broadcasts on this topic whenever a worker has
just persisted a batch of new entries.

```
{:entries_ingested, source_id, entries}
```

`source_id` is the binary id of the source that produced the batch.
`entries` is a list of entry structs in consumption order, where each
entry includes at least `id` and `url`. The order of the list is
significant. Downstream subscribers may rely on it for stable
delivery semantics.

This topic has two subscribers today. `Producer.Router` uses it to
fan entries out to subscribed sinks. `Extractor.Router` uses it to
start one extraction task per entry.

### `catalog:changed`

The catalog broadcasts on this topic whenever a resource that affects
worker topology changes. It is the signal that the control planes
should reconcile.

`Consumer.Coordinator` uses it to spawn or update worker processes
when sources are added, enabled, or disabled.
`Producer.Router` uses it to bootstrap workers for newly added sinks
and to refresh its view of subscriptions.

### `extraction:complete`

The extractor pipeline broadcasts on this topic after it has
successfully persisted a new or replaced artifact. Subscribers that
need to react to the existence of a rendered body for an entry can
listen here rather than polling the catalog. There are no first-party
subscribers today. The topic exists so that future producer adapters
and downstream consumers can hook in without changing the
publisher.

## How to use the wrapper

`Claptrap.PubSub` exposes three operations.

```elixir
Claptrap.PubSub.subscribe(Claptrap.PubSub.topic_entries_new())
Claptrap.PubSub.broadcast(topic, message)
Claptrap.PubSub.broadcast!(topic, message)
```

Subscribers must always go through the wrapper's `topic_*` helpers
rather than the raw string. This keeps the topic name owned by one
module and makes it easy to grep for every publisher and subscriber.

The wrapper is the only place that should call `Phoenix.PubSub`
directly. Any new topic should be added as a constant and a helper
function in `Claptrap.PubSub`, and any new subscriber should look the
topic up through that helper at runtime rather than hard-coding the
string.

## Failure semantics

`Phoenix.PubSub` delivers messages best-effort. A broadcast does not
wait for subscribers to acknowledge. If a subscriber crashes while
processing a message, the message is lost from that subscriber's
perspective, and the subscriber's supervisor restarts it with a
fresh mailbox.

This is the right shape for Claptrap because the catalog is the
durable source of truth for everything that PubSub announces. A
subscriber that misses an `entries_ingested` event can rediscover the
missed entries by querying the catalog, and a subscriber that misses
a `catalog_changed` event will pick up the change on the next
periodic reconcile.

PubSub is the fast path. The catalog is the slow path. Subsystems
that need to be correct in the face of restarts always check the
catalog, and use PubSub only for latency.
