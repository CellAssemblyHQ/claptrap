# Glossary

## Data entities

### Entry

The atomic unit of content in Claptrap. An entry represents a discrete
piece of consumable information such as a blog post, news article, or
conference talk. Within the cluster, all content is normalized to
entries regardless of its original source format.

### Source

An external or upstream provider of content to consume into Claptrap. A source
is a configuration record in the Catalog. Each source has an associated
**consumer adapter** that normalizes source-native content into entries.

### Sink

A downstream destination for entries. A sink is a configuration record in the
Catalog. Each sink has an associated **producer adapter** that transforms
entries into a sink-native representation.

### Subscription

A rule that links entries to sinks based on **tag matching** -- sinks subscribe
to tags, not to specific sources.

When entries are consumed, the `Producer.Router` matches each entry's
resolved tag set against subscriptions. Every subscription with at least one
overlapping tag receives the entry for delivery to its sink.

### Tag

A string label used as the sole routing dimension in Claptrap. Tags
connect sources to sinks indirectly.

- **Source tags**: configured on source resources, inherited by every
  entry consumed from that source
- **Content-derived tags**: applied by consumer adapters during
  consumption
- **Entry tags**: the persisted union of inherited source tags and
  content-derived tags

## Subsystems

### Catalog

The central registry. Connects to PostgreSQL to manage all resource
definitions. Provides a domain-facing API to surrounding processes.

### Consumer

A worker process that consumes entries from a source. There's one consumer
process per configured source. Delegates protocol-specific work to a **consumer
adapter**.

### Producer

A worker process that publishes entries to a sink. There's one producer process
per configured sink. Delegates protocol-specific work to a **producer adapter**.

### API

The external HTTP interface. Exposes REST endpoints for clients outside
the cluster.

## Adapters

A pure module (no process, no state) that transforms between the Entry format
and a specific external protocol. Adapters implement a behaviour and are called
by workers.
