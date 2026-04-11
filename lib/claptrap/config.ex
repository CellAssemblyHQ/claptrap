defmodule Claptrap.Config do
  @moduledoc false

  @repo_schema [
    username: [type: :string, required: true],
    password: [type: :string, required: true],
    port: [type: :pos_integer, required: true],
    database: [type: :string],
    hostname: [type: :string],
    pool_size: [type: :pos_integer],
    pool: [type: :any],
    url: [type: :string],
    ssl: [type: :any],
    show_sensitive_data_on_connection_error: [type: :boolean]
  ]

  @extraction_schema [
    formats: [type: {:list, :string}, default: []],
    adapters: [type: :any, default: %{}]
  ]

  @storage_schema [
    backend: [type: :atom],
    root_dir: [type: :string]
  ]

  @firecrawl_schema [
    api_key: [type: :any],
    base_url: [type: :string, default: "https://api.firecrawl.dev"]
  ]

  @app_schema [
    api_key: [type: :any],
    port: [type: :any]
  ]

  def validate! do
    repo_config =
      :claptrap
      |> Application.get_env(Claptrap.Repo, [])
      |> validate_subsystem!("Claptrap.Repo", @repo_schema)
      |> put_subsystem!(Claptrap.Repo)

    extraction_config =
      :claptrap
      |> Application.get_env(:extraction, [])
      |> validate_subsystem!(":extraction", @extraction_schema)
      |> validate_extraction_adapters!()
      |> put_subsystem!(:extraction)

    storage_config =
      :claptrap
      |> Application.get_env(Claptrap.Storage, [])
      |> validate_subsystem!("Claptrap.Storage", @storage_schema)
      |> validate_storage_backend!()
      |> put_subsystem!(Claptrap.Storage)

    :claptrap
    |> Application.get_env(:firecrawl, [])
    |> validate_subsystem!(":firecrawl", @firecrawl_schema)
    |> validate_firecrawl_config!()
    |> put_subsystem!(:firecrawl)

    :claptrap
    |> Application.get_all_env()
    |> validate_subsystem!(":claptrap", @app_schema)
    |> validate_app_config!()
    |> put_app_env!()

    validate_extraction_storage_pair!(extraction_config, storage_config)
    repo_config
  end

  defp put_subsystem!(validated_config, key) do
    Application.put_env(:claptrap, key, validated_config)
    validated_config
  end

  defp put_app_env!(validated_config) do
    Enum.each(validated_config, fn
      {key, value} when is_atom(key) and key not in [Claptrap.Repo, Claptrap.Storage] ->
        Application.put_env(:claptrap, key, value)

      _ ->
        :ok
    end)

    validated_config
  end

  defp validate_subsystem!(config, subsystem, schema) do
    normalized = normalize_config!(config, subsystem)

    case validate_with_passthrough(normalized, schema) do
      {:ok, validated} ->
        validated

      {:error, %NimbleOptions.ValidationError{} = e} ->
        raise ArgumentError,
              "Invalid configuration for #{subsystem}: #{Exception.message(e)}"
    end
  end

  defp validate_with_passthrough(config, schema) do
    known_keys = Keyword.keys(schema)
    {known, extra} = Keyword.split(config, known_keys)

    case NimbleOptions.validate(known, schema) do
      {:ok, validated} -> {:ok, Keyword.merge(validated, extra)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_config!(config, _subsystem) when is_list(config), do: config
  defp normalize_config!(config, _subsystem) when is_nil(config), do: []
  defp normalize_config!(config, _subsystem) when is_map(config), do: Map.to_list(config)

  defp normalize_config!(config, subsystem) do
    raise ArgumentError,
          "Invalid configuration for #{subsystem}: expected keyword list or map, got: #{inspect(config)}"
  end

  defp validate_extraction_adapters!(config) do
    adapters = Keyword.get(config, :adapters, %{})

    unless is_map(adapters) do
      raise ArgumentError,
            "Invalid configuration for :extraction: :adapters must be a map of string => atom"
    end

    Enum.each(adapters, fn
      {format, adapter} when is_binary(format) and is_atom(adapter) ->
        :ok

      {format, adapter} ->
        raise ArgumentError,
              "Invalid configuration for :extraction: adapter entries must be string => atom, got #{inspect({format, adapter})}"
    end)

    config
  end

  defp validate_storage_backend!(config) do
    if config != [] and not Keyword.has_key?(config, :backend) do
      raise ArgumentError,
            "Invalid configuration for Claptrap.Storage: :backend is required when storage is configured"
    end

    config
  end

  defp validate_app_config!(config) do
    validate_app_api_key!(Keyword.get(config, :api_key))
    validate_app_port!(Keyword.get(config, :port))
    config
  end

  defp validate_firecrawl_config!(config) do
    validate_firecrawl_api_key!(Keyword.get(config, :api_key))
    config
  end

  defp validate_firecrawl_api_key!(nil), do: :ok
  defp validate_firecrawl_api_key!(key) when is_binary(key), do: :ok

  defp validate_firecrawl_api_key!(value) do
    raise ArgumentError,
          "Invalid configuration for :firecrawl: :api_key must be a string or nil, got: #{inspect(value)}"
  end

  defp validate_app_api_key!(nil), do: :ok
  defp validate_app_api_key!(key) when is_binary(key), do: :ok

  defp validate_app_api_key!(value) do
    raise ArgumentError,
          "Invalid configuration for :claptrap: :api_key must be a string or nil, got: #{inspect(value)}"
  end

  defp validate_app_port!(nil), do: :ok
  defp validate_app_port!(port) when is_integer(port) and port >= 0, do: :ok

  defp validate_app_port!(value) do
    raise ArgumentError,
          "Invalid configuration for :claptrap: :port must be a non-negative integer or nil, got: #{inspect(value)}"
  end

  defp validate_extraction_storage_pair!(extraction_config, storage_config) do
    formats = Keyword.get(extraction_config, :formats, [])

    extraction_configured? = formats != []
    storage_configured? = storage_config != [] and Keyword.has_key?(storage_config, :backend)

    case {extraction_configured?, storage_configured?} do
      {true, false} ->
        raise ArgumentError,
              "Extraction is configured but no storage backend is set. Both must be configured together."

      {false, true} ->
        raise ArgumentError,
              "A storage backend is configured but no extraction formats are set. Both must be configured together."

      _ ->
        :ok
    end
  end
end
