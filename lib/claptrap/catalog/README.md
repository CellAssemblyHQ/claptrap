# Catalog

The catalog is Claptrap's domain layer. It owns every
structured record that flows through the system — sources,
entries, sinks, subscriptions, and artifacts — and is the only
subsystem that talks to `Claptrap.Repo` directly. Every other
subsystem reads and writes catalog data through the
`Claptrap.Catalog` facade module in `../catalog.ex`.

Keeping persistence behind one facade has two payoffs.
Subsystems don't need to know which database is in use, and
business rules (validation, defaults, status transitions) live
in one place rather than scattered across handlers, workers,
and adapters.

## Architecture

```
Source ──has_many──▶ Entry ──has_many──▶ Artifact
  │                    │                    (extracted content,
  │ tags               │ tags                 keyed by format)
  │                    │
  │         ┌──────────┘
  │         │  (matched via Postgres && array overlap)
  │         ▼
Sink ──has_many──▶ Subscription
                      │
                      │ tags
```

There is no direct foreign key between entries and sinks. The
connection is implicit: when an entry's tags overlap with a
subscription's tags, the entry is routed to that subscription's
sink. The actual routing happens in `Claptrap.Producer`; the
catalog just defines the shape.

## The five entities

**Source** is an input feed — typically an RSS URL. It tracks
`type`, `name`, `config`, `credentials`, `enabled`, `tags`, and
a `last_consumed_at` polling cursor. The consumer subsystem
polls sources on a schedule.

**Entry** is a piece of content ingested from a source. Status
is one of `"unread"`, `"in_progress"`, `"read"`, `"archived"`.
A unique constraint on `[external_id, source_id]` prevents
duplicate ingestion when the consumer re-polls.

**Artifact** is a derived representation of an entry (markdown,
html, or pdf), produced by the extractor subsystem. The unique
constraint `[entry_id, format]` means re-extraction upserts
rather than duplicates.

**Sink** is an output destination — typically an RSS feed to
generate. It mirrors Source structurally (`type`, `name`,
`config`, `credentials`, `enabled`) minus `tags` and
`last_consumed_at`.

**Subscription** links a sink to a set of tags. It's the
routing record: entries whose tags overlap are delivered to the
associated sink.

## Conventions

All schemas use UUID primary keys (`{:id, :binary_id,
autogenerate: true}` plus `@foreign_key_type :binary_id`) and
microsecond timestamps (`timestamps(type: :utc_datetime_usec)`).

Source and Sink both carry a `credentials` map. It's writable
via changesets but excluded from `Jason.Encoder`, so credentials
never appear in API responses. New credential-bearing schemas
should follow the same pattern.

## Module layout

The five `.ex` files at the top level are the Ecto schemas.
`server.ex` is a small named GenServer placeholder — supervised
and exposing a no-op `list_sources/1` today, but in place so
future stateful catalog operations have a process to live in.
`supervisor.ex` is a `:one_for_one` supervisor that starts it.

The public API of the catalog lives in `../catalog.ex`, not
here. This directory holds the schemas and the (currently
minimal) processes; the facade is where the functions other
subsystems call live.

## Notes

- Tags appear on Source, Entry, and Subscription. The Postgres
  `&&` array-overlap operator is the routing mechanism.
- Source tags are inherited by entries at ingest time, so
  retagging a source only affects future ingests.
- Artifact `format` is constrained to `"markdown" | "html" |
  "pdf"` at the schema level — extending this requires a
  schema change.
