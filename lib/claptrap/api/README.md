# API

A Plug-based JSON REST API over Claptrap's catalog resources.
The API layer is deliberately thin: handlers parse the request,
delegate to `Claptrap.Catalog`, and serialize the result.
Handlers never touch Ecto or the Repo directly.

Two consequences fall out of that. Every business rule that
matters lives in the catalog, not here — if you're trying to
understand *why* a request succeeded or failed, this is rarely
the right place to look. And the OpenAPI spec is generated from
the same handlers that serve traffic, so the spec and the
implementation cannot drift.

## Architecture

```
HTTP Request
  │
  ▼
Plug pipeline               ← logger, JSON parser,
  │                            Auth (Bearer token),
  ▼                            error rescue
Router                       ← /health, /ready, /api/v1/openapi
  │
  ├─ /api/v1/sources/*       → Handlers.Sources
  ├─ /api/v1/sinks/*         → Handlers.Sinks
  ├─ /api/v1/subscriptions/* → Handlers.Subscriptions
  ├─ /api/v1/entries/*       → Handlers.Entries
  └─ /api/v1/artifacts/*     → Handlers.Artifacts
```

`handlers/` contains one `Plug.Router` per resource. They share
the same shape: bang-variant catalog fetches for 404 behaviour,
`json/3` for responses, and `Pagination` helpers for list
envelopes. `operations/` and `schemas/` are OpenApiSpex modules
— operations declare endpoint contracts, schemas declare
resource shapes plus shared envelopes (`Error`,
`ValidationError`, `Pagination`).

## Authentication

Every endpoint requires `Authorization: Bearer <token>` except
`/health` and `/ready`. The expected token comes from
`:api_key` in application config and is compared with
`Plug.Crypto.secure_compare/2`. Missing or invalid tokens
return `401`. There is no per-user identity, no scopes, and no
session — it's a single shared secret.

## CRUD coverage

Not every resource exposes full CRUD:

| Resource      | List | Create | Get | Update | Delete |
|---------------|------|--------|-----|--------|--------|
| Sources       | ✓    | ✓      | ✓   | ✓      | ✓      |
| Sinks         | ✓    | ✓      | ✓   | ✓      | ✓      |
| Subscriptions | ✓    | ✓      | ✓   |        | ✓      |
| Entries       | ✓    | ✓      | ✓   | ✓      |        |
| Artifacts     | ✓    | ✓      | ✓   |        | ✓      |

The gaps are intentional. Subscriptions are immutable once
created — to change the tag set, delete and recreate. Entries
can't be deleted via the API because deletion would cascade to
artifacts in confusing ways; remove them through the catalog
directly if needed. Artifacts can't be updated because they're
derived data — re-extract instead.

## Error handling

Handlers call bang-variant catalog functions (`get_source!/1`,
etc.) that raise `Ecto.NoResultsError` on missing records. The
top-level plug rescues these globally:

- `Ecto.NoResultsError` → 404
- `Ecto.Query.CastError` → 400
- anything else → 500

This means handlers don't need explicit "not found" branches.
Changeset errors from create/update are returned by the catalog
as `{:error, changeset}` and serialized as `422` with a
field-keyed error map.

## OpenAPI

The generated spec is served at `/api/v1/openapi`, assembled
from `operations/` and `schemas/` via OpenApiSpex at request
time. The spec is also validated as part of `mix check`, so
regressions surface before merge.

## Operational notes

- All responses are `application/json`.
- List endpoints accept pagination params and return a shared
  `{items, meta}` envelope via `Claptrap.Pagination`.
- Filter parameters are handler-specific: sources and sinks
  support `?enabled=`, subscriptions support `?sink_id=`,
  entries support `?status=`, `?source_id=`, and `?limit=`,
  and artifacts support `?entry_id=`.
