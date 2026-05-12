# Sources

Upstream source resources, their role in consumption, and their relationship
to entries and subscriptions.

A source is a configured upstream content origin that Claptrap knows
how to consume.

Examples include:

- An RSS or Atom feed
- A YouTube channel or playlist
- A Zotero library
- A Goodreads account or shelf
- An inbound webhook endpoint

Sources describe **where content comes from** and **how Claptrap
should talk to that upstream system**.

## Responsibilities

The Catalog owns sources as durable resources so other subsystems can
rely on a stable definition for:

- Worker bootstrap
- Scheduling and polling
- Adapter selection
- Configuration validation
- Source lifecycle management

## Source identity

A source has a Claptrap-owned identity independent of upstream item
identity.

- `source.id` identifies the configured integration instance
- `entry.external_id` identifies a specific upstream item within that
  source's namespace

This separation is critical for idempotency and worker management.

## Source fields

A source resource typically includes:

| Field | Purpose |
| --- | --- |
| Primary key | Claptrap-owned UUID |
| Type / adapter kind | Determines which consumer adapter to use |
| Config | Normalized configuration (URL, filters, etc.) |
| Credentials | Encrypted API keys, OAuth tokens |
| Enabled | Operational state |
| Scheduling metadata | Polling cadence for pull sources |
| Tags | Tags inherited by consumed entries |
| Timestamps | Lifecycle metadata |

## Validation boundary

The Catalog enforces shared structural invariants. The selected adapter
validates source-type-specific configuration through
`validate_config/1`.

This keeps the Catalog as the control-plane boundary without turning
it into a grab bag of protocol-specific logic.

## Operational role

Consumers use sources to determine which workers to run:

- `Catalog.list_sources(filters)` lets `Consumer.Coordinator`
  bootstrap workers
- Source change events tell the consumer subsystem to start, stop, or
  reconfigure workers

## Relationship to entries

A source may emit many entries. The source records the durable upstream
integration definition; entries record normalized discovered content.

- Source lifecycle: configuration and consumption behavior
- Entry lifecycle: normalized discovered content

## Relationship to subscriptions

Sources do not participate directly in subscriptions. Subscriptions
match against entry tags, not source resources.

However, sources influence routing indirectly: tags configured on a
source are inherited by every entry consumed from it. Adding a tag to
a source automatically changes which subscriptions match its entries.
