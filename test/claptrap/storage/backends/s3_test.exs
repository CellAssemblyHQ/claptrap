defmodule Claptrap.Storage.Backends.S3Test do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Claptrap.Storage.Backends.S3
  alias Testcontainers.MinioContainer

  setup_all do
    ensure_testcontainers_started()

    {:ok, container} = Testcontainers.start_container(MinioContainer.new())
    on_exit(fn -> :ok = Testcontainers.stop_container(container.container_id) end)

    bucket = "claptrap-s3-test-#{:erlang.unique_integer([:positive])}"
    config = minio_storage_config(container, bucket)

    assert {:ok, _} =
             ExAws.S3.put_bucket(bucket, config.region)
             |> ExAws.request(ex_aws_overrides(config))

    %{config: config}
  end

  setup %{config: config} do
    key_prefix = "s3-backend-test/#{:erlang.unique_integer([:positive])}/"
    %{config: config, key_prefix: key_prefix}
  end

  describe "write/3" do
    test "small payload round-trip", ctx do
      key = full_key(ctx, "hello.txt")

      assert :ok = S3.write(key, ["hello ", "world"], ctx.config)
      assert {:ok, stream} = S3.read(key, ctx.config)
      assert "hello world" == Enum.join(stream)
    end

    test "multipart upload when payload is above 5 MiB", ctx do
      key = full_key(ctx, "multipart.bin")
      chunk = String.duplicate("x", 65_536)
      chunk_count = 96
      expected_bytes = chunk_count * byte_size(chunk)

      assert :ok = S3.write(key, List.duplicate(chunk, chunk_count), ctx.config)
      assert {:ok, stream} = S3.read(key, ctx.config)
      assert expected_bytes == stream |> Enum.to_list() |> IO.iodata_to_binary() |> byte_size()
    end

    test "empty enumerable writes a zero-byte object", ctx do
      key = full_key(ctx, "empty.bin")

      assert :ok = S3.write(key, [], ctx.config)
      assert {:ok, true} = S3.exists?(key, ctx.config)
    end
  end

  describe "read/2" do
    test "returns not_found for missing key", ctx do
      assert {:error, :not_found} = S3.read(full_key(ctx, "missing.txt"), ctx.config)
    end

    test "returns error tuple for unreachable endpoint", ctx do
      bad_config = %{ctx.config | host: "127.0.0.1", port: 1}
      assert {:error, _reason} = S3.read(full_key(ctx, "missing.txt"), bad_config)
    end
  end

  describe "delete/2" do
    test "deletes an existing key", ctx do
      key = full_key(ctx, "to-delete.txt")

      assert :ok = S3.write(key, ["payload"], ctx.config)
      assert :ok = S3.delete(key, ctx.config)
      assert {:ok, false} = S3.exists?(key, ctx.config)
    end

    test "returns not_found for missing key", ctx do
      assert {:error, :not_found} = S3.delete(full_key(ctx, "missing.txt"), ctx.config)
    end

    test "returns error tuple for unreachable endpoint", ctx do
      bad_config = %{ctx.config | host: "127.0.0.1", port: 1}
      assert {:error, _reason} = S3.delete(full_key(ctx, "missing.txt"), bad_config)
    end
  end

  describe "list/2" do
    test "lists keys for a prefix in sorted order", ctx do
      report_prefix = full_key(ctx, "reports/")
      a_key = "#{report_prefix}a.txt"
      b_key = "#{report_prefix}b.txt"
      c_key = "#{report_prefix}c.txt"

      assert :ok = S3.write(b_key, ["b"], ctx.config)
      assert :ok = S3.write(c_key, ["c"], ctx.config)
      assert :ok = S3.write(a_key, ["a"], ctx.config)
      assert :ok = S3.write(full_key(ctx, "other/outside.txt"), ["x"], ctx.config)

      assert {:ok, [^a_key, ^b_key, ^c_key]} = S3.list(report_prefix, ctx.config)
    end

    test "returns empty list for empty prefix scope", ctx do
      assert {:ok, []} = S3.list(full_key(ctx, "no-objects/"), ctx.config)
    end

    test "handles pagination beyond 1000 keys", ctx do
      prefix = full_key(ctx, "many/")

      keys =
        for i <- 1..1_005 do
          key = "#{prefix}#{String.pad_leading(Integer.to_string(i), 4, "0")}.txt"
          assert :ok = S3.write(key, ["value-#{i}"], ctx.config)
          key
        end

      assert {:ok, listed_keys} = S3.list(prefix, ctx.config)
      assert listed_keys == Enum.sort(keys)
    end

    test "returns error tuple instead of raising on backend errors", ctx do
      missing_bucket_config = %{ctx.config | bucket: "#{ctx.config.bucket}-missing"}

      assert {:error, _reason} = S3.list(full_key(ctx, "anything/"), missing_bucket_config)
    end

    test "returns error tuple for unreachable endpoint", ctx do
      bad_config = %{ctx.config | host: "127.0.0.1", port: 1}
      assert {:error, _reason} = S3.list(full_key(ctx, "anything/"), bad_config)
    end
  end

  describe "exists?/2" do
    test "returns true for existing key", ctx do
      key = full_key(ctx, "exists.txt")

      assert :ok = S3.write(key, ["present"], ctx.config)
      assert {:ok, true} = S3.exists?(key, ctx.config)
    end

    test "returns false for missing key", ctx do
      assert {:ok, false} = S3.exists?(full_key(ctx, "missing.txt"), ctx.config)
    end

    test "returns error tuple for unreachable endpoint", ctx do
      bad_config = %{ctx.config | host: "127.0.0.1", port: 1}
      assert {:error, _reason} = S3.exists?(full_key(ctx, "missing.txt"), bad_config)
    end
  end

  defp ensure_testcontainers_started do
    case Testcontainers.start() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp minio_storage_config(container, bucket) do
    host = Testcontainers.get_host()
    port = MinioContainer.port(container)

    %{
      bucket: bucket,
      access_key_id: MinioContainer.get_username(),
      secret_access_key: MinioContainer.get_password(),
      region: "us-east-1",
      host: host,
      scheme: "http://",
      port: port
    }
  end

  defp full_key(ctx, suffix), do: ctx.key_prefix <> suffix

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
end
