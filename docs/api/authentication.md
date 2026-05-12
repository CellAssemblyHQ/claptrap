# Authentication

The Claptrap HTTP API is protected by a single static bearer token.
Every request to `/api/v1/*` must carry that token in an
`Authorization` header. The two operational probes, `/health` and
`/ready`, are the only routes that bypass authentication, so that
external monitoring can reach them without holding credentials.

## How requests are authenticated

Authenticated requests must include the header

```
Authorization: Bearer <token>
```

where `<token>` matches the configured API key exactly. The
comparison is performed by `Claptrap.API.Auth` using
`Plug.Crypto.secure_compare/2`, which is a constant-time comparison
designed to avoid leaking information through response timing.

Any request that fails authentication receives a halted `401`
response with a JSON body of `{"error": "unauthorized"}`. The
response does not distinguish between a missing header, a malformed
header, and an incorrect token. This is deliberate, so that an
attacker probing the endpoint cannot tell which of those three
failure modes applies.

## Where the token comes from

The expected token lives at `Application.get_env(:claptrap, :api_key)`.
In development this is hard-coded to `dev-api-key` in
`config/dev.exs`, which makes local exploration straightforward. In
production the token is read at runtime from the `CLAPTRAP_API_KEY`
environment variable. If the variable is not set, the application
refuses to boot rather than starting with an empty key.

The plug also accepts an `:api_key` option directly, which is used
only in tests to override the configured key for a single request
pipeline. Application code should not rely on that path.

## Allowlisted routes

Two routes skip the auth check entirely.

`GET /health` always returns `200` with the body
`{"status": "ok"}`. It exercises only the HTTP server and is meant
as a liveness probe.

`GET /ready` runs `SELECT 1` against the configured Ecto repository
and returns `200` with `{"status": "ready"}` on success or `503`
with `{"status": "unavailable"}` on failure. It is meant as a
readiness probe that reflects the application's ability to serve
real traffic.

The allowlist is configurable through the `:except` option on
`Claptrap.API.Auth.init/1`, but `["/health", "/ready"]` is the only
combination used in production.

## Example

A working request against a development server looks like this.

```
curl -H "Authorization: Bearer dev-api-key" \
  http://localhost:4000/api/v1/sources
```

The same request without the header returns `401`.

```
curl -i http://localhost:4000/api/v1/sources

HTTP/1.1 401 Unauthorized
content-type: application/json
{"error":"unauthorized"}
```

## Rotating the token

Because the token is a single static string, rotating it requires
updating `CLAPTRAP_API_KEY` in the deployment environment and then
restarting the application so that the new value is picked up by
`runtime.exs`. There is no support for multiple simultaneous tokens
today, so any clients holding the old value must be updated in lock
step with the rotation.
