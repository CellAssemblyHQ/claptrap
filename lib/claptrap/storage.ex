defmodule Claptrap.Storage do
  @moduledoc """
  Public interface to Claptrap's blob storage subsystem.

  This module provides a small, key-addressed API for storing and
  retrieving opaque binary data. It is intentionally decoupled from
  the Catalog (which owns structured records in PostgreSQL) and is
  designed for artifacts that do not fit naturally into relational
  tables, such as extracted page content, cached feed bodies, or
  generated output files.

  ## Backend delegation

  `Claptrap.Storage` does not implement persistence itself. Every
  call is forwarded to a backend module that implements the
  `Claptrap.Storage.Adapter` behaviour. The backend is selected at
  runtime from application configuration:

      config :claptrap, Claptrap.Storage,
        backend: Claptrap.Storage.Backends.Local,
        root_dir: "priv/storage"

  The `:backend` key identifies the adapter module. All remaining
  keys are collected into a map and passed to the adapter as its
  `config` argument. This keeps the public API backend-agnostic
  while allowing each adapter to define its own configuration
  shape.

  ## Key format

  Keys are flat, non-empty strings that must match the pattern:

      [a-zA-Z0-9][a-zA-Z0-9._-]*

  This means a key must start with an alphanumeric character and
  may then contain alphanumerics, dots, underscores, and hyphens.
  The following are rejected and will raise `ArgumentError`:

    * Empty strings
    * Absolute paths (leading `/`)
    * Path separators (`/`) — this also prevents traversal
      sequences like `../`
    * Hidden-file prefixes (leading `.`)
    * Whitespace or special characters
    * Null bytes

  The same pattern is applied to the `prefix` argument of `list/1`,
  with the exception that an empty string is allowed to mean "list
  everything".

  ## Streaming data

  Write data is accepted as any `Enumerable` of iodata chunks,
  which allows callers to pipe data through without materializing
  the full payload in memory. Read results are returned as lazy
  streams for the same reason. This streaming contract is defined
  by the `Claptrap.Storage.Adapter` behaviour.

  ## Example

      :ok = Claptrap.Storage.write("feed-cache.xml", [xml_body])

      {:ok, stream} = Claptrap.Storage.read("feed-cache.xml")
      body = Enum.join(stream)

      {:ok, true} = Claptrap.Storage.exists?("feed-cache.xml")

      {:ok, keys} = Claptrap.Storage.list("feed-")

      :ok = Claptrap.Storage.delete("feed-cache.xml")
  """

  @key_pattern ~r/\A[a-zA-Z0-9][a-zA-Z0-9.\/_-]*\z/
  @prefix_pattern ~r/\A[a-zA-Z0-9][a-zA-Z0-9.\/_-]*\z/

  def write(key, data) do
    validate_key!(key)
    backend().write(key, data, backend_config())
  end

  def read(key) do
    validate_key!(key)
    backend().read(key, backend_config())
  end

  def delete(key) do
    validate_key!(key)
    backend().delete(key, backend_config())
  end

  def list(prefix \\ "") do
    validate_prefix!(prefix)
    backend().list(prefix, backend_config())
  end

  def exists?(key) do
    validate_key!(key)
    backend().exists?(key, backend_config())
  end

  defp config, do: Application.fetch_env!(:claptrap, __MODULE__)
  defp backend, do: Keyword.fetch!(config(), :backend)

  defp backend_config do
    config() |> Keyword.delete(:backend) |> Map.new()
  end

  defp validate_key!(key) do
    unless Regex.match?(@key_pattern, key) do
      raise ArgumentError, "invalid storage key: #{inspect(key)}"
    end

    :ok
  end

  defp validate_prefix!(""), do: :ok

  defp validate_prefix!(prefix) do
    unless Regex.match?(@prefix_pattern, prefix) do
      raise ArgumentError, "invalid storage prefix: #{inspect(prefix)}"
    end

    :ok
  end
end
