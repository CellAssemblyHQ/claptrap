# Claptrap

A personal router for your information diet. Claptrap monitors your favorite sources, normalizes each entry into an aggregated store, and routes the content back to your preferred format.

Content flows through three primitives: **Sources** (where content comes from), **Sinks** (where it goes), and **Subscriptions** (tag-based rules that connect them). You never wire sources to sinks directly — tags are the sole routing dimension.

## Quick Start

**Prerequisites**: Elixir ~> 1.17, Erlang/OTP 28+, PostgreSQL on port 5432.

```bash
mix setup              # fetch deps, create database, run migrations
mix run --no-halt      # start the server on http://localhost:4000
```

Verify the server is healthy:

```bash
curl http://localhost:4000/health
# {"status":"ok"}
```

In development, the API bearer token is hard-coded to `dev-api-key`. Every request to `/api/v1/*` requires this header:

```bash
curl -H "Authorization: Bearer dev-api-key" http://localhost:4000/api/v1/sources
```

## Core Workflow

### 1. Add a source

A source tells Claptrap where to pull content from. Tags on the source are inherited by every entry it produces.

**RSS source** — required config field: `url`.

```bash
curl -X POST http://localhost:4000/api/v1/sources \
  -H "Authorization: Bearer dev-api-key" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "rss",
    "name": "Hacker News",
    "config": { "url": "https://news.ycombinator.com/rss" },
    "tags": ["tech", "news"],
    "enabled": true
  }'
```

An RSS source polls the feed URL and normalizes each item into an entry. Items with an `<enclosure>` carrying an audio MIME type become `podcast` entries; everything else becomes `article`.

### 2. Add a sink

A sink is a delivery target — where matched entries are sent.

**RSS feed sink** — materializes routed entries as a consumable RSS feed. Required config fields: `description` and `link` (an absolute `http`/`https` URL). Optional: `max_entries` (default 50).

```bash
curl -X POST http://localhost:4000/api/v1/sinks \
  -H "Authorization: Bearer dev-api-key" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "rss",
    "name": "My Tech Feed",
    "config": {
      "description": "Aggregated tech articles",
      "link": "https://claptrap.example.com",
      "max_entries": 100
    },
    "enabled": true
  }'
```

### 3. Create a subscription

Subscriptions route entries to sinks using tag overlap. Any entry whose tag set intersects the subscription's tags is delivered.

```bash
curl -X POST http://localhost:4000/api/v1/subscriptions \
  -H "Authorization: Bearer dev-api-key" \
  -H "Content-Type: application/json" \
  -d '{
    "sink_id": "<sink-uuid>",
    "tags": ["tech"],
    "enabled": true
  }'
```

A source tagged `["tech", "news"]` matches a subscription for `["tech"]` because the sets overlap. No explicit source-to-sink wiring is needed — adding a new source tagged `"tech"` automatically feeds every sink subscribed to that tag.

### 4. Query entries

```bash
# List recent entries (default page size: 25, max: 100)
curl -H "Authorization: Bearer dev-api-key" \
  "http://localhost:4000/api/v1/entries?page_size=10"

# Paginate with the cursor from next_page_token
curl -H "Authorization: Bearer dev-api-key" \
  "http://localhost:4000/api/v1/entries?page_token=<cursor>"
```

Response shape:

```json
{
  "items": [
    {
      "id": "uuid",
      "type": "article",
      "title": "Example Post",
      "url": "https://example.com/post",
      "tags": ["tech", "blog"],
      "published_at": "2026-05-11T00:00:00Z"
    }
  ],
  "next_page_token": "<opaque cursor>"
}
```

`next_page_token` is only present when there is a next page.

### 5. Retrieve extracted content

After entries are ingested, the extractor fetches the full document and stores a normalized rendering as an artifact. Artifacts hold the Markdown or HTML body of an entry.

```bash
# List all artifacts for a specific entry
curl -H "Authorization: Bearer dev-api-key" \
  "http://localhost:4000/api/v1/artifacts?entry_id=<entry-uuid>"
```

Response shape:

```json
{
  "items": [
    {
      "id": "uuid",
      "entry_id": "uuid",
      "format": "markdown",
      "content": "# Article Title\n\nFull extracted body...",
      "content_type": "text/markdown",
      "byte_size": 4096,
      "extractor": "firecrawl"
    }
  ]
}
```

```bash
# Get a single artifact by ID
curl -H "Authorization: Bearer dev-api-key" \
  http://localhost:4000/api/v1/artifacts/<artifact-uuid>
```

An entry may have one artifact per format (e.g., one `markdown` and one `html`). If no artifact exists yet, extraction is still in progress or was skipped because the entry had no URL.

## Content Types

Every entry is normalized to one of five types regardless of its upstream source format:

| Type | Description |
| --- | --- |
| `article` | Blog posts, essays, newsletters |
| `video` | YouTube videos, Vimeo videos |
| `podcast` | Podcast episodes with audio enclosures |
| `book` | Goodreads books, Zotero book items |
| `paper` | Journal articles, conference papers, preprints |

Type is determined per-entry by the consumer adapter, not per-source. An RSS feed can produce both `article` and `podcast` entries.

## Configuration

All runtime configuration is read from environment variables. Set these before starting the server in production.

| Variable | Required | Default | Purpose |
| --- | --- | --- | --- |
| `CLAPTRAP_API_KEY` | yes | `dev-api-key` (dev only) | Bearer token for the HTTP API |
| `DATABASE_HOST` | yes | — | Postgres hostname |
| `DATABASE` | yes | — | Postgres database name |
| `DATABASE_USERNAME` | yes | — | Postgres username |
| `DATABASE_PASSWORD` | yes | — | Postgres password |
| `DATABASE_PORT` | no | `5432` | Postgres port |
| `POOL_SIZE` | no | `10` | Ecto connection pool size |
| `FIRECRAWL_API_KEY` | yes | — | API key for the Firecrawl extractor |
| `FIRECRAWL_BASE_URL` | no | `https://api.firecrawl.dev` | Override for self-hosted Firecrawl |
| `PORT` | no | `4000` | TCP port Bandit listens on |

Storage defaults to the local filesystem. To use a different backend, set it in `config/runtime.exs`:

```elixir
config :claptrap, Claptrap.Storage,
  backend: Claptrap.Storage.Backends.S3,
  bucket: "my-claptrap-bucket"
```

## Deployment

Claptrap ships with a `Dockerfile` and is designed for [Fly.io](https://fly.io):

```bash
fly launch        # detects Dockerfile, provisions Postgres
fly secrets set CLAPTRAP_API_KEY="your-key" FIRECRAWL_API_KEY="your-key"
fly deploy        # runs migrations on first boot
```

Health and readiness probes are built in:
- `GET /health` — liveness probe (`{"status":"ok"}`)
- `GET /ready` — readiness probe, checks database connectivity

See [docs/deploy-fly.md](docs/deploy-fly.md) for the full deployment guide including scaling, external Postgres, and troubleshooting.

## Development

```bash
mix check                       # format + compile + credo + tests (run before PR)
mix test                        # test suite only
mix test path/to/test.exs:42   # single test by file and line
mix ecto.reset                  # drop, recreate, and migrate the database
mix openapi.export              # regenerate priv/openapi/v1.json from running app
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full development workflow, project structure, and code style guide.

## Further Reading

- [Glossary](docs/glossary.md) — Sources, Sinks, Subscriptions, Entries, Tags, Adapters
- [Architecture](docs/architecture/) — Data flow, supervision tree, subsystem design
- [API Reference](docs/api/index.md) — REST endpoints, pagination, error shapes
- [Authentication](docs/api/authentication.md) — Bearer token contract and token rotation
- [Configuration](docs/configuration.md) — Every config key and environment variable
- [Catalog](docs/catalog/) — Entry types, source/sink/subscription schemas
