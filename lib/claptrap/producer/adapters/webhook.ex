defmodule Claptrap.Producer.Adapters.Webhook do
  @moduledoc """
  Push-mode producer adapter for webhook sinks.

  This module currently provides configuration validation and callback stubs.
  Actual webhook delivery logic will be implemented in a follow-up change.
  """

  @behaviour Claptrap.Producer.Adapter

  @reserved_header_names [
    "content-type",
    "x-webhook-signature",
    "x-webhook-timestamp",
    "x-webhook-delivery-id"
  ]

  @impl true
  def mode, do: :push

  @impl true
  def materialize(_sink, _entries), do: {:error, :not_supported}

  @impl true
  def push(_sink, _entries), do: {:error, :not_implemented}

  @impl true
  def validate_config(config) when is_map(config) do
    with :ok <- validate_url(config),
         :ok <- validate_headers(config),
         :ok <- validate_timeout_ms(config) do
      validate_max_batch_size(config)
    end
  end

  def validate_config(_), do: {:error, "config must be a map"}

  defp validate_url(%{"url" => url}) when is_binary(url) do
    case String.trim(url) do
      "" -> {:error, "url must be a non-empty absolute URI with http or https scheme"}
      trimmed_url -> validate_absolute_http_uri(trimmed_url)
    end
  end

  defp validate_url(%{"url" => _}),
    do: {:error, "url must be a non-empty absolute URI with http or https scheme"}

  defp validate_url(_),
    do: {:error, "missing required key: url"}

  defp validate_absolute_http_uri(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      :ok
    else
      {:error, "url must be a non-empty absolute URI with http or https scheme"}
    end
  end

  defp validate_headers(%{"headers" => headers}) when is_map(headers) do
    Enum.reduce_while(headers, :ok, fn
      {key, value}, _acc when not is_binary(key) or not is_binary(value) ->
        {:halt, {:error, "headers must be a map with string keys and string values"}}

      {key, _value}, _acc ->
        downcased_key = String.downcase(key)

        if downcased_key in @reserved_header_names do
          {:halt, {:error, "headers contains reserved key: #{downcased_key}"}}
        else
          {:cont, :ok}
        end
    end)
  end

  defp validate_headers(%{"headers" => _}),
    do: {:error, "headers must be a map with string keys and string values"}

  defp validate_headers(_), do: :ok

  defp validate_timeout_ms(%{"timeout_ms" => timeout_ms})
       when not is_integer(timeout_ms) or timeout_ms <= 0,
       do: {:error, "timeout_ms must be a positive integer"}

  defp validate_timeout_ms(_), do: :ok

  defp validate_max_batch_size(%{"max_batch_size" => max_batch_size})
       when not is_integer(max_batch_size) or max_batch_size <= 0,
       do: {:error, "max_batch_size must be a positive integer"}

  defp validate_max_batch_size(_), do: :ok
end
