defmodule Claptrap.Storage.Backends.S3 do
  @moduledoc """
  S3-compatible storage adapter.

  This backend supports AWS S3 and S3-compatible providers (for
  example Cloudflare R2, MinIO, and Backblaze B2) by sending
  per-request ExAws overrides from backend config instead of relying
  on global ExAws application config.
  """

  @behaviour Claptrap.Storage.Adapter

  @min_part_size 5_242_880

  @impl true
  def write(key, data, %{bucket: bucket} = config) do
    data
    |> rechunk(@min_part_size)
    |> ExAws.S3.upload(bucket, key)
    |> ExAws.request(ex_aws_overrides(config))
    |> normalize_result()
  end

  @impl true
  def read(key, %{bucket: bucket} = config) do
    overrides = ex_aws_overrides(config)

    case ExAws.S3.head_object(bucket, key) |> ExAws.request(overrides) do
      {:ok, _} ->
        aws_config = ExAws.Config.new(:s3, overrides)
        {:ok, url} = ExAws.S3.presigned_url(aws_config, :get, bucket, key)
        req_stream(url)

      {:error, {:http_error, 404, _}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def delete(key, %{bucket: bucket} = config) do
    overrides = ex_aws_overrides(config)

    case ExAws.S3.head_object(bucket, key) |> ExAws.request(overrides) do
      {:ok, _} ->
        ExAws.S3.delete_object(bucket, key)
        |> ExAws.request(overrides)
        |> normalize_result()

      {:error, {:http_error, 404, _}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list(prefix, %{bucket: bucket} = config) do
    bucket
    |> list_paginated(prefix, ex_aws_overrides(config), nil, [])
    |> case do
      {:ok, keys} -> {:ok, Enum.sort(keys)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def exists?(key, %{bucket: bucket} = config) do
    case ExAws.S3.head_object(bucket, key) |> ExAws.request(ex_aws_overrides(config)) do
      {:ok, _} -> {:ok, true}
      {:error, {:http_error, 404, _}} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ex_aws_overrides(config) do
    [
      access_key_id: config.access_key_id,
      secret_access_key: config.secret_access_key,
      region: config.region,
      host: config.host,
      scheme: config.scheme,
      port: config.port
    ]
  end

  defp normalize_result({:ok, _}), do: :ok
  defp normalize_result({:error, reason}), do: {:error, reason}

  defp rechunk(enumerable, min_size) do
    Stream.transform(
      enumerable,
      fn -> {<<>>, false} end,
      fn chunk, {buffer, seen_chunk?} ->
        buffer = IO.iodata_to_binary([buffer, chunk])

        if byte_size(buffer) >= min_size do
          {[buffer], {<<>>, true}}
        else
          {[], {buffer, seen_chunk? || byte_size(chunk) > 0}}
        end
      end,
      fn
        {buffer, _seen_chunk?} when byte_size(buffer) > 0 -> {[buffer], {<<>>, true}}
        {<<>>, false} -> {[<<>>], {<<>>, true}}
        {<<>>, true} -> {[], {<<>>, true}}
      end,
      fn _state -> :ok end
    )
  end

  defp req_stream(url) do
    case Req.get(url, into: :self) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: 404} = response} ->
        maybe_cancel_async_response(response)
        {:error, :not_found}

      {:ok, %Req.Response{status: status, body: body} = response} ->
        maybe_cancel_async_response(response)
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_cancel_async_response(%Req.Response{body: %Req.Response.Async{}} = response) do
    Req.cancel_async_response(response)
  end

  defp maybe_cancel_async_response(_response), do: :ok

  defp list_paginated(bucket, prefix, overrides, continuation_token, acc) do
    opts =
      [prefix: prefix]
      |> maybe_put_continuation_token(continuation_token)

    case ExAws.S3.list_objects_v2(bucket, opts) |> ExAws.request(overrides) do
      {:ok, %{body: body}} ->
        keys = body |> Map.get(:contents, []) |> Enum.map(& &1.key)
        next_acc = keys ++ acc

        if body[:is_truncated] == "true" do
          list_paginated(bucket, prefix, overrides, body[:next_continuation_token], next_acc)
        else
          {:ok, next_acc}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_continuation_token(opts, nil), do: opts
  defp maybe_put_continuation_token(opts, token), do: Keyword.put(opts, :continuation_token, token)
end
