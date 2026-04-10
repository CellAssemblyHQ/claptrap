defmodule Claptrap.MixProject do
  use Mix.Project

  def project do
    [
      app: :claptrap,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/project.plt"},
        plt_add_apps: [:mix, :ex_unit]
      ]
    ]
  end

  def cli do
    [preferred_envs: [check: :test]]
  end

  def application do
    [
      mod: {Claptrap.Application, []},
      extra_applications: [:logger, :xmerl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support", "test/e2e/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # HTTP
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.6"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:nimble_options, "~> 1.1"},
      {:sweet_xml, "~> 0.7"},
      {:open_api_spex, "~> 3.21"},

      # Database
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:castore, "~> 1.0"},
      {:paginator, "~> 1.2"},
      # Override: paginator pins plug_crypto ~> 1.2
      # but only uses non_executable_binary_to_term/2
      # which is unchanged in 2.x
      {:plug_crypto, "~> 2.1", override: true},

      # PubSub
      {:phoenix_pubsub, "~> 2.1"},

      # Dev/test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
      {:testcontainers, "~> 2.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["cmd git config core.hooksPath priv/hooks", "deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "openapi.check",
        "dialyzer",
        "test"
      ]
    ]
  end
end
