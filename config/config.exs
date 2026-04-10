import Config

config :claptrap,
  ecto_repos: [Claptrap.Repo]

config :claptrap, Claptrap.Repo,
  database: "claptrap_#{config_env()}",
  hostname: "localhost"

config :claptrap, :firecrawl,
  api_key: nil,
  base_url: "https://api.firecrawl.dev"

config :claptrap, :extraction,
  formats: ["markdown"],
  adapters: %{
    "markdown" => Claptrap.Extractor.Adapters.Firecrawl,
    "html" => Claptrap.Extractor.Adapters.Firecrawl
  }

config :claptrap, Claptrap.Storage,
  backend: Claptrap.Storage.Backends.Local,
  root_dir: Path.join(Path.expand("..", __DIR__), "priv/storage")

import_config "#{config_env()}.exs"
