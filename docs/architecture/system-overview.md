# System overview

Claptrap is structured as a set of Elixir/OTP processes that consume
content from external sources, normalize it into a common internal
representation, and deliver it to downstream sinks.

## Why Elixir/OTP

Claptrap is fundamentally a system of concurrent, long-running
processes that need to:

- **Consume sources on independent schedules** (e.g. RSS feeds
  every 15 min)
- **Deliver entries to multiple sinks concurrently** (e.g. RSS
  feeds — each with different delivery semantics)
- **Stay alive indefinitely** as a personal daemon, recovering
  gracefully from failures in any individual component

This is [exactly the problem space Erlang/OTP was designed for](https://en.wikipedia.org/wiki/Open_Telecom_Platform).

## Major subsystems

| Subsystem    | Responsibility |
| ------------ | --- |
| **Catalog**  | Central registry. Manages all resource definitions in PostgreSQL. |
| **Consumer** | Pull and normalizes content into entries. |
| **Producer** | Packages entries into output formats. |
| **API**      | External HTTP interface. |

## Roles vs transport

**Consumer vs Producer is defined by direction across the Claptrap
boundary**, not by who initiates network I/O.

- **Consumer**: external → Entry (ingress)
- **Producer**: Entry → external (egress)

**Push vs pull** is a boundary transport detail:

- Pull sources are scheduled or polled by Claptrap
- Pull sinks are materialized by Claptrap and served via HTTP
