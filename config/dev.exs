import Config

config :claptrap, Claptrap.Repo,
  username: "postgres",
  password: "postgres",
  port: 5432,
  pool_size: 10,
  show_sensitive_data_on_connection_error: true

config :claptrap, api_key: "dev-api-key"

config :logger, level: :debug
