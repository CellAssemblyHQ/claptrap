# Subscriptions

Tag-based routing relationships between sources and sinks, with array
overlap matching semantics.

A subscription is a Catalog-owned routing rule that determines how
entries are delivered to sinks based on tag matching.

## Motivation

Subscriptions make producer routing policy explicit. Neither sources
nor sinks own the routing decision. A subscription is the durable,
queryable record that tells routers where to direct entries.

Sources and sinks are completely decoupled — neither references the
other. Tags are the sole routing dimension.

## How routing works

A subscription binds a sink to a set of tags. When entries are
consumed, the `Producer.Router` matches each entry's resolved tag set
against all active subscriptions using array overlap (ANY semantics).

```
entry.tags && subscription.tags → deliver to subscription.sink_id
```

### Tag resolution

Tags on entries are resolved at consume time as the **union** of:

1. **Inherited tags** — configured on the source, automatically
   inherited by every entry
2. **Content-derived tags** — applied by the consumer adapter based on
   content or upstream metadata

The entry's persisted `tags` field is the canonical set used for all
routing. The router never looks up the source's tags at delivery time.

### Matching semantics

A subscription with tags `["tech"]` matches any entry whose tag set
contains `"tech"`, regardless of other tags.

- Source tagged `["tech", "news"]` → entries get at least
  `["tech", "news"]`
- Subscription `["tech"]` matches because `["tech"] && ["tech", "news"]`
  is true
- Subscription `["podcasts"]` does not match unless the adapter also
  tagged the entry

### Automatic routing

Adding a new source tagged `["tech"]` automatically routes its entries
to all sinks with subscriptions containing `"tech"`. No explicit wiring
required.

Adding a new subscription for `["tech"]` on a sink immediately begins
matching entries from any source that produces `"tech"`-tagged content.

## Subscription lifecycle

A subscription may be enabled or disabled. Disabled subscriptions are
ignored during routing but retained for auditability and
re-enablement.

## Catalog API

The primary query interface:

```elixir
def subscriptions_for_tags(entry_tags) do
  from(s in Subscription,
    where: fragment("? && ?", s.tags, ^entry_tags),
    where: s.enabled == true,
    select: s.sink_id
  )
  |> Repo.all()
end
```

A GIN index on `subscriptions.tags` makes this overlap query efficient.

## Schema

```elixir
schema "subscriptions" do
  belongs_to :sink, Claptrap.Schemas.Sink
  field :tags, {:array, :string}
  field :enabled, :boolean, default: true

  timestamps(type: :utc_datetime_usec)
end
```

Required fields: `sink_id`, `tags` (minimum 1 tag).

## Migration requirements

The subscriptions table requires:

- A foreign key from `sink_id` to `sinks.id`
- A GIN index on `tags` for efficient `&&` queries
- An index on `sink_id` for reverse lookups
