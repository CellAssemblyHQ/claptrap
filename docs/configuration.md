# Configuration

Claptrap reads configuration from two layers. Compile-time defaults
live in `config/config.exs` and the per-environment files
`config/dev.exs`, `config/test.exs`, and `config/runtime.exs`. Anything
that varies between deployments, including credentials, hostnames, and
API keys, is read at runtime from environment variables inside
`config/runtime.exs`. This page is the single reference for every
configuration key the application understands and every environment
variable it consults.

## Environment variables

The variables below are read by `config/runtime.exs`. Variables marked
required must be set in production or the application will refuse to
start. Variables marked optional have either a code default or a
sensible fallback.

| Variable | Used in | Required | Default | Purpose |
| --- | --- | --- | --- | --- |
| `DATABASE_HOST` | prod | required | none | Postgres hostname for the application repo |
| `DATABASE` | prod | required | none | Postgres database name |
| `DATABASE_USERNAME` | prod | required | none | Postgres username |
| `DATABASE_PASSWORD` | prod | required | none | Postgres password |
| `DATABASE_PORT` | prod | optional | `5432` | Postgres port |
| `POOL_SIZE` | prod | optional | `10` | Ecto pool size |
| `DATABASE_HOSTNAME` | all | optional | unset | Overrides the repo hostname in any environment when set |
| `DATABASE_URL` | test | optional | unset | If set in `:test`, uses the SQL sandbox against this URL |
| `CLAPTRAP_API_KEY` | prod | required | none | Bearer token required by the HTTP API |
| `FIRECRAWL_API_KEY` | prod | required | none | API key for the Firecrawl extractor adapter |
| `FIRECRAWL_BASE_URL` | prod | optional | `https://api.firecrawl.dev` | Base URL for Firecrawl, useful for self-hosted instances |
| `PORT` | all | optional | `4000` | TCP port that Bandit listens on |

In development the API bearer token is hard-coded to `dev-api-key`
inside `config/dev.exs` so that local clients can authenticate without
extra setup. Do not rely on that value outside of development.

## Application configuration

The keys below live under the `:claptrap` application and can be set
in any of the config files. The values shown are the defaults from
`config/config.exs` unless noted otherwise.

### `:claptrap, :api_key`

The bearer token expected by the HTTP API. In production this is
populated from `CLAPTRAP_API_KEY` at runtime. In development it
defaults to `dev-api-key`. The API auth plug compares incoming tokens
against this value using `Plug.Crypto.secure_compare/2`, and rejects
any request that does not match.

### `:claptrap, :port`

The TCP port that Bandit listens on. If not set, the application
falls back to the `PORT` environment variable, then to `4000`. This
key is mostly useful in tests, which set it explicitly to avoid port
collisions.

### `:claptrap, :ecto_repos`

The list of Ecto repos that Mix tasks such as `mix ecto.migrate`
should operate on. Currently this is just `[Claptrap.Repo]`. There is
no reason to change it.

### `:claptrap, Claptrap.Repo`

Standard Ecto repo configuration. The default `config.exs` sets
`database: "claptrap_#{config_env()}"` and `hostname: "localhost"`.
The development environment adds `username`, `password`, `port`, and
`pool_size`. Production is fully populated from environment variables
in `runtime.exs` and additionally enables TLS with peer verification.

### `:claptrap, :firecrawl`

Credentials for the Firecrawl extractor adapter. The shape is

```elixir
config :claptrap, :firecrawl,
  api_key: nil,
  base_url: "https://api.firecrawl.dev"
```

`api_key` is sent as a Bearer token on every scrape request. In
production it must come from `FIRECRAWL_API_KEY` or the runtime config
will raise. `base_url` defaults to the hosted Firecrawl service but
can be repointed at a self-hosted deployment.

### `:claptrap, :firecrawl_req_options`

Optional keyword list that is merged into the `Req` request used by
the Firecrawl adapter. It exists so that tests can inject a stubbed
transport, and so that operators can tune timeouts or other transport
options without changing code. There is no default.

### `:claptrap, :extraction`

Controls which formats the extractor produces and which adapter
handles each one. The default is

```elixir
config :claptrap, :extraction,
  formats: ["markdown"],
  adapters: %{
    "markdown" => Claptrap.Extractor.Adapters.Firecrawl,
    "html" => Claptrap.Extractor.Adapters.Firecrawl
  }
```

`:formats` is the list of formats the router will request for every
ingested entry. Setting it to `[]` disables extraction without
removing the subsystem from the supervision tree. `:adapters` maps
each format string to a module implementing
`Claptrap.Extractor.Adapter`. A format that appears in `:formats` but
not in `:adapters` will be logged and skipped at runtime. See the
[extractor architecture](architecture/extractor.md) for the full
pipeline behavior.

### `:claptrap, Claptrap.Storage`

Configures the blob storage subsystem. The shape is

```elixir
config :claptrap, Claptrap.Storage,
  backend: Claptrap.Storage.Backends.Local,
  root_dir: "priv/storage"
```

`:backend` is the adapter module. Every other key in this block is
passed to that adapter as its configuration map. The default backend
is the local filesystem adapter, which expects a `:root_dir` path.
See the [storage architecture](architecture/storage.md) for the full
adapter contract.

## Where each value is set

The same key is often configured in more than one place because
defaults flow from `config.exs` and are overridden in environment
files or in `runtime.exs`. The precedence is, from lowest to highest,
`config/config.exs`, then `config/{dev,test,prod}.exs`, then
`config/runtime.exs`. Anything that comes from the environment must
be in `runtime.exs` so that release builds pick it up at boot rather
than at compile time.
