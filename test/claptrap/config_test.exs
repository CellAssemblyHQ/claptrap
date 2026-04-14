defmodule Claptrap.ConfigTest do
  use ExUnit.Case, async: false

  alias Claptrap.Config

  @env_keys [
    {:claptrap, Claptrap.Repo},
    {:claptrap, :extraction},
    {:claptrap, Claptrap.Storage},
    {:claptrap, :firecrawl},
    {:claptrap, :api_key},
    {:claptrap, :port}
  ]

  setup do
    previous =
      for {app, key} <- @env_keys, into: %{} do
        {{app, key}, Application.get_env(app, key)}
      end

    on_exit(fn ->
      Enum.each(previous, fn {{app, key}, value} ->
        if is_nil(value) do
          Application.delete_env(app, key)
        else
          Application.put_env(app, key, value)
        end
      end)
    end)

    :ok
  end

  describe "validate!/0" do
    test "happy path: valid config passes" do
      put_valid_config()

      assert Config.validate!()
    end

    test "missing required DB field raises" do
      put_valid_config()
      Application.put_env(:claptrap, Claptrap.Repo, Keyword.delete(valid_repo_config(), :username))

      assert_raise ArgumentError, ~r/Invalid configuration for Claptrap\.Repo/, fn ->
        Config.validate!()
      end
    end

    test "wrong type for required DB field raises" do
      put_valid_config()
      Application.put_env(:claptrap, Claptrap.Repo, Keyword.put(valid_repo_config(), :port, "5432"))

      assert_raise ArgumentError, ~r/Invalid configuration for Claptrap\.Repo/, fn ->
        Config.validate!()
      end
    end

    test "extraction configured without storage raises" do
      put_valid_config()
      Application.delete_env(:claptrap, Claptrap.Storage)

      assert_raise ArgumentError,
                   "Extraction is configured but no storage backend is set. Both must be configured together.",
                   fn ->
                     Config.validate!()
                   end
    end

    test "storage configured without extraction raises" do
      put_valid_config()
      Application.put_env(:claptrap, :extraction, formats: [], adapters: %{})

      assert_raise ArgumentError,
                   "A storage backend is configured but no extraction formats are set. Both must be configured together.",
                   fn ->
                     Config.validate!()
                   end
    end

    test "both extraction and storage configured passes" do
      put_valid_config()
      assert Config.validate!()
    end

    test "neither extraction nor storage configured passes" do
      put_valid_config()
      Application.put_env(:claptrap, :extraction, formats: [], adapters: %{})
      Application.delete_env(:claptrap, Claptrap.Storage)

      assert Config.validate!()
    end

    test "firecrawl config absent entirely passes" do
      put_valid_config()
      Application.delete_env(:claptrap, :firecrawl)

      assert Config.validate!()
    end
  end

  defp put_valid_config do
    Application.put_env(:claptrap, Claptrap.Repo, valid_repo_config())
    Application.put_env(:claptrap, :extraction, formats: ["markdown"], adapters: valid_adapters_config())
    Application.put_env(:claptrap, Claptrap.Storage, backend: Claptrap.Storage.Backends.Local)
    Application.put_env(:claptrap, :firecrawl, api_key: nil, base_url: "https://api.firecrawl.dev")
    Application.put_env(:claptrap, :api_key, "test-api-key")
    Application.put_env(:claptrap, :port, 4000)
  end

  defp valid_repo_config do
    [
      username: "postgres",
      password: "postgres",
      port: 5432,
      database: "claptrap_test",
      hostname: "localhost",
      pool_size: 10
    ]
  end

  defp valid_adapters_config do
    %{
      "markdown" => Claptrap.Extractor.Adapters.Firecrawl
    }
  end
end
