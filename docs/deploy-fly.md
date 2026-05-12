# Deploy to Fly.io

This guide walks through deploying Claptrap to [Fly.io](https://fly.io), a
platform that runs Docker containers close to your users. Fly is a natural
fit for Claptrap because it supports long-running processes, managed
Postgres, and straightforward secret management.

## Prerequisites

- A [Fly.io account](https://fly.io/app/sign-up)
- The [`flyctl` CLI](https://fly.io/docs/flyctl/install/) installed and
  authenticated (`fly auth login`)
- A [Firecrawl](https://firecrawl.dev) API key

## Launch the app

From the root of the Claptrap repository, run:

```bash
fly launch
```

Fly detects the existing `Dockerfile` and generates a `fly.toml`
configuration file. When prompted:

- Choose a **region** close to you (e.g. `ord` for Chicago)
- Say **yes** to creating a Postgres database — Fly will provision a
  managed cluster and automatically set `DATABASE_URL` on the app

> **Warning:** Do not deploy yet when `fly launch` asks — you need to
> configure secrets first.

## Set secrets

Claptrap requires three environment variables in production. Fly secrets
are encrypted and injected at runtime, so they never appear in your
`fly.toml`.

```bash
fly secrets set \
  CLAPTRAP_API_KEY="your-api-key" \
  FIRECRAWL_API_KEY="your-firecrawl-key"
```

`DATABASE_URL` is already set if you created Postgres during `fly launch`.
You can verify with:

```bash
fly secrets list
```

### Optional variables

| Variable             | Default                         | Description                        |
| -------------------- | ------------------------------- | ---------------------------------- |
| `POOL_SIZE`          | `10`                            | Database connection pool size      |
| `FIRECRAWL_BASE_URL` | `https://api.firecrawl.dev`     | Override for self-hosted Firecrawl |

## Using an external Postgres database

If you prefer to bring your own Postgres instance (e.g. Supabase, Neon,
AWS RDS, or a self-hosted server) instead of Fly's managed offering,
skip the Postgres prompt during `fly launch` and set `DATABASE_URL`
yourself:

```bash
fly secrets set DATABASE_URL="postgres://user:password@host:5432/claptrap"
```

A few things to keep in mind:

- **SSL** — most hosted providers require SSL. Append `?sslmode=require`
  to the connection string if your provider enforces it.
- **Connection limits** — free-tier hosted databases often cap connections
  at 20-25. Set `POOL_SIZE` to stay comfortably below the limit:
  ```bash
  fly secrets set POOL_SIZE="5"
  ```
- **Latency** — pick a database region close to the Fly region you
  selected for the app. Cross-continent round trips add noticeable
  latency to every query.
- **Firewall / allowlists** — if your provider requires IP allowlisting,
  you can find the egress IPs for your Fly app with `fly ips list`.
  Some providers also support private networking via WireGuard or AWS
  PrivateLink, which avoids allowlisting entirely.

## Configure `fly.toml`

After `fly launch` generates your `fly.toml`, verify the following
sections. Adjust as needed:

```toml
[http_service]
  internal_port = 4000
  force_https = true

  [[http_service.checks]]
    interval = "10s"
    timeout = "2s"
    grace_period = "10s"
    method = "GET"
    path = "/health"
```

The `internal_port` must be `4000` to match the port Claptrap listens on.
The health check uses the `/health` endpoint built into the API.

## Deploy

```bash
fly deploy
```

Fly builds the Docker image remotely, pushes it, and starts the release.
On first deploy the Ecto migrations run automatically as part of the
release boot.

Verify the app is running:

```bash
fly status
```

Open the app in your browser:

```bash
fly open /health
```

You should see a `200` response confirming the service is healthy.

## Run database migrations

Migrations run during the release boot sequence. If you ever need to run
them manually:

```bash
fly ssh console -C "/app/bin/claptrap eval 'Claptrap.Release.migrate()'"
```

## Scaling

Fly defaults to a single shared-CPU machine. For a personal instance this
is usually sufficient. To scale up:

```bash
# Increase VM size
fly scale vm shared-cpu-2x

# Add more memory (in MB)
fly scale memory 512
```

Because Claptrap is a single-tenant personal daemon, a single machine in
one region is typically all you need.

## Troubleshooting

**View logs**

```bash
fly logs
```

**Open a remote shell**

```bash
fly ssh console -C "/app/bin/claptrap remote"
```

This drops you into a live IEx session on the running node — useful for
inspecting processes, checking the supervision tree, or running ad-hoc
queries against the Repo.

**Postgres connection issues**

If the app cannot reach the database, verify the attachment:

```bash
fly postgres list
fly postgres attach <db-app-name> --app <claptrap-app-name>
```

This resets `DATABASE_URL` on the app with the correct internal
connection string.
