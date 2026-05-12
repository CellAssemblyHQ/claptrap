# API reference

Claptrap exposes a versioned REST API under `/api/v1` for managing
every resource in the Catalog. The API is the only supported way for
external clients to read or modify Claptrap state. All internal
subsystems go through `Claptrap.Catalog` directly rather than through
HTTP.

The canonical machine-readable description of the API lives in
[`openapi/v1.json`](../openapi/v1.json) and is also served at runtime
from `GET /api/v1/openapi`. The file in this repository is generated
from the running application by `mix openapi.export`, and `mix
openapi.check` verifies that the committed file matches the current
code.

## Base URL

In production the base URL is whatever hostname the application is
deployed under, followed by `/api/v1`. The OpenAPI document advertises

```
https://docs.claptrap.dev/api/v1
```

as its server URL. In development the base URL is
`http://localhost:4000/api/v1`.

## Authentication

Every route under `/api/v1` requires a bearer token in the
`Authorization` header. The only exceptions are `/health` and
`/ready`, which bypass auth so that external monitoring can reach
them. See the [authentication page](authentication.md) for the full
contract, including the failure response shape and how the token is
configured.

## Resources

The API exposes five top-level resources. Each one corresponds to a
Catalog entity and is documented in the catalog section.

| Resource | Endpoint root | Reference |
| --- | --- | --- |
| Entries | `/api/v1/entries` | [Entries](../catalog/entries.md) |
| Artifacts | `/api/v1/artifacts` | [Artifacts](../catalog/artifacts.md) |
| Sources | `/api/v1/sources` | [Sources](../catalog/sources.md) |
| Sinks | `/api/v1/sinks` | [Sinks](../catalog/sinks.md) |
| Subscriptions | `/api/v1/subscriptions` | [Subscriptions](../catalog/subscriptions.md) |

The exact set of operations on each resource, including request and
response schemas, is in the OpenAPI document. The catalog pages
linked above describe what each resource means and the rules that
apply to it.

## Response shape

All responses are JSON. Successful list responses follow the
pagination envelope described below. Successful single-resource
responses return the resource object directly. Successful mutations
return the resulting resource.

### Pagination

List endpoints return responses of the shape

```json
{
  "items": [ ... ],
  "next_page_token": "<opaque cursor>"
}
```

`next_page_token` is only included when there is a next page. To
fetch the next page, pass the cursor back as the `page_token` query
parameter on the same endpoint. The page size is controlled by the
`page_size` query parameter, which defaults to 25 and is capped at
100. Values outside that range are clamped to the default rather
than rejected.

### Errors

Errors are returned with an appropriate HTTP status code and a JSON
body. Authentication failures return `401` with
`{"error": "unauthorized"}`. Validation failures return `422` with a
structured object describing which fields failed and why. Not-found
responses return `404` with `{"error": "not found"}`. The OpenAPI
document is the authoritative source for the exact error schema on
each endpoint.

## Operational endpoints

Two routes outside `/api/v1` exist purely for operations.

`GET /health` returns `200` with `{"status": "ok"}` and exercises
only the HTTP server. Use it as a liveness probe.

`GET /ready` runs `SELECT 1` against the application database and
returns `200` with `{"status": "ready"}` on success or `503` with
`{"status": "unavailable"}` on failure. Use it as a readiness probe.

`GET /api/v1/openapi` returns the current OpenAPI document generated
from code. Unlike `/health` and `/ready`, this route is protected by
the same bearer token as every other API route.
