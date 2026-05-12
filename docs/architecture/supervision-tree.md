# Supervision tree

Process hierarchy, restart strategies, and failure domains in Claptrap's OTP
supervision tree.

Every box in the supervision tree is a process or supervisor managing
processes. The tree is read top-down: parents start before children,
and a parent crashing takes its entire subtree down.

## Complete supervision tree

```
Claptrap.Application (OTP Application root)
|
+-- Claptrap.Repo (Ecto -- PostgreSQL connection pool)
|     Started first because every other subsystem needs
|     the database.
|
+-- Claptrap.Registry (Registry -- process name registry)
|     Maps {type, id} tuples to PIDs. Used by all
|     subsystems.
|
+-- Claptrap.PubSub (Phoenix.PubSub -- internal event bus)
|     In-process pub/sub. Decouples consumers from
|     producers.
|
+-- Consumer.Supervisor -- strategy: :rest_for_one
|   +-- Consumer.WorkerSupervisor (DynamicSupervisor,
|   |     :one_for_one)
|   |   +-- Consumer.Worker (RSS: "Hacker News")
|   |   +-- Consumer.Worker (RSS: "lobste.rs")
|   |   +-- Consumer.Worker (YouTube: "@channel")
|   |   +-- ... one process per configured source
|   |
|   +-- Consumer.Coordinator (GenServer)
|         Reconciles running workers with catalog sources
|         on a periodic :tick schedule.
|
+-- Producer.Supervisor -- strategy: :rest_for_one
|   +-- Producer.WorkerSupervisor (DynamicSupervisor,
|   |     :one_for_one)
|   |   +-- Producer.Worker (RSS Feed: "combined")
|   |   +-- Producer.Worker (Webhook: "https://...")
|   |   +-- ... one process per configured sink
|   |
|   +-- Producer.Router (GenServer)
|         Subscribes to "entries:new", routes to matching
|         sinks.
|
+-- Bandit (HTTP server, plug: Claptrap.API.Plug)
```

## Why this tree has this shape

The supervision tree encodes failure domain design.

### Shared infrastructure as direct children

Repo, Registry, and PubSub are direct children of the Application
supervisor. Every subsystem depends on these. By making them direct
children rather than nesting them, a shared dependency failure does
not unnecessarily cascade through unrelated worker hierarchies.

### Consumer and Producer use `:rest_for_one`

The Coordinator or Router depends on its WorkerSupervisor existing. If
the WorkerSupervisor crashes and all workers disappear, those
higher-level processes hold stale references. `:rest_for_one` ensures
the dependent process is restarted after the WorkerSupervisor.

### WorkerSupervisors use `:one_for_one`

Each worker is independent. One RSS feed crashing should not affect a
YouTube worker. One webhook sink failure should not restart an email
sink worker.

### Bandit as a direct child

The HTTP server (Bandit) is a direct child of the Application
supervisor rather than nested under a separate API supervisor.

## Failure domain summary

- Shared infrastructure failure is handled at the application root
- Per-source and per-sink failures are isolated to individual workers
- Coordinator and Router are restarted when their worker topology
  becomes invalid
