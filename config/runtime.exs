import Config

required! = fn name ->
  System.get_env(name) ||
    raise "Required environment variable #{name} is not set"
end

# All envs — PORT
config :claptrap, port: String.to_integer(System.get_env("PORT") || "4000")

# All envs — DATABASE_HOSTNAME
if db_host = System.get_env("DATABASE_HOSTNAME") do
  config :claptrap, Claptrap.Repo, hostname: db_host
end

# Test — DATABASE_URL
if config_env() == :test do
  if url = System.get_env("DATABASE_URL") do
    config :claptrap, Claptrap.Repo,
      url: url,
      pool: Ecto.Adapters.SQL.Sandbox
  end
end

# Prod
if config_env() == :prod do
  db_host = required!.("DATABASE_HOST")

  config :claptrap, Claptrap.Repo,
    database: required!.("DATABASE"),
    hostname: db_host,
    port: String.to_integer(System.get_env("DATABASE_PORT") || "5432"),
    username: required!.("DATABASE_USERNAME"),
    password: required!.("DATABASE_PASSWORD"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    ssl: [
      verify: :verify_peer,
      cacertfile: CAStore.file_path(),
      server_name_indication: String.to_charlist(db_host),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

  config :claptrap, api_key: required!.("CLAPTRAP_API_KEY")

  config :claptrap, :firecrawl,
    api_key: required!.("FIRECRAWL_API_KEY"),
    base_url: System.get_env("FIRECRAWL_BASE_URL", "https://api.firecrawl.dev")
end
