# Sinks

Delivery target resources, their role in producer execution, and their
relationship to subscriptions.

A sink is a configured delivery target that Claptrap can route
processed content to.

Examples include:

- Email delivery targets
- Webhook destinations
- Chat or messaging endpoints (Slack)
- Combined RSS feed generation
- File or export targets

A sink describes **where content goes after normalization and routing**.

## Responsibilities

The Catalog owns sinks so the rest of the system has a stable registry
for delivery configuration:

- Creating and updating sink definitions
- Validating shared sink structure
- Delegating sink-type-specific validation to producer adapters
- Resolving sink configuration for delivery workers

## Operational role

Producer-side components use sinks as the source of truth for delivery:

- `Catalog.sinks_for_source(source_id)` helps `Producer.Router`
  determine delivery targets
- `Catalog.get_sink!(sink_id)` lets `Producer.Workers` load
  configuration for delivery

## Boundary semantics

A sink is configuration, not delivery state. The sink resource is the
durable declarative target definition. Transient delivery attempts,
retries, and failures belong to runtime execution or job state.

## Sink fields

A sink resource typically includes:

| Field | Purpose |
| --- | --- |
| Primary key | Claptrap-owned UUID |
| Type / adapter kind | Determines which producer adapter to use |
| Config | Destination configuration (webhook URL, feed title, etc.) |
| Credentials | Encrypted credentials |
| Enabled | Operational state |
| Timestamps | Lifecycle metadata |

## Validation boundary

As with sources, the Catalog owns the resource lifecycle and the
selected producer adapter validates sink-specific configuration
details.

## Relationship to subscriptions

Sinks are not directly attached to entries. They are selected through
subscriptions. A sink can receive content from multiple sources, and
routing policy remains explicit and inspectable.
