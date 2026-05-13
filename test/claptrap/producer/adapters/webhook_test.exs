defmodule Claptrap.Producer.Adapters.WebhookTest do
  use ExUnit.Case, async: true

  alias Claptrap.Catalog.Sink
  alias Claptrap.Producer.Adapters.Webhook

  describe "mode/0" do
    test "returns :push" do
      assert Webhook.mode() == :push
    end
  end

  describe "materialize/2" do
    test "returns error not_supported" do
      sink = %Sink{id: Ecto.UUID.generate(), type: "webhook", name: "Test", config: %{}}
      assert {:error, :not_supported} = Webhook.materialize(sink, [])
    end
  end

  describe "push/2" do
    test "returns error not_implemented" do
      sink = %Sink{id: Ecto.UUID.generate(), type: "webhook", name: "Test", config: %{}}
      assert {:error, :not_implemented} = Webhook.push(sink, [])
    end
  end

  describe "validate_config/1" do
    test "accepts valid minimal config" do
      assert :ok = Webhook.validate_config(%{"url" => "https://example.com/hook"})
    end

    test "accepts valid full config" do
      assert :ok =
               Webhook.validate_config(%{
                 "url" => "https://example.com/hook",
                 "headers" => %{"X-Tenant-Id" => "abc"},
                 "timeout_ms" => 5_000,
                 "max_batch_size" => 10
               })
    end

    test "rejects missing url" do
      assert {:error, "missing required key: url"} = Webhook.validate_config(%{})
    end

    test "rejects empty url" do
      assert {:error, "url must be a non-empty absolute URI with http or https scheme"} =
               Webhook.validate_config(%{"url" => ""})
    end

    test "rejects whitespace-only url" do
      assert {:error, "url must be a non-empty absolute URI with http or https scheme"} =
               Webhook.validate_config(%{"url" => "   "})
    end

    test "rejects non-http url scheme" do
      assert {:error, "url must be a non-empty absolute URI with http or https scheme"} =
               Webhook.validate_config(%{"url" => "ftp://example.com"})
    end

    test "rejects relative url" do
      assert {:error, "url must be a non-empty absolute URI with http or https scheme"} =
               Webhook.validate_config(%{"url" => "/webhook"})
    end

    test "rejects headers that are not a map" do
      assert {:error, "headers must be a map with string keys and string values"} =
               Webhook.validate_config(%{"url" => "https://example.com/hook", "headers" => []})
    end

    test "rejects headers with non-string value" do
      assert {:error, "headers must be a map with string keys and string values"} =
               Webhook.validate_config(%{
                 "url" => "https://example.com/hook",
                 "headers" => %{"X-Trace-Id" => 123}
               })
    end

    test "rejects reserved header key X-Webhook-Signature case-insensitively" do
      assert {:error, "headers contains reserved key: x-webhook-signature"} =
               Webhook.validate_config(%{
                 "url" => "https://example.com/hook",
                 "headers" => %{"X-Webhook-Signature" => "sig"}
               })
    end

    test "rejects reserved header key content-type" do
      assert {:error, "headers contains reserved key: content-type"} =
               Webhook.validate_config(%{
                 "url" => "https://example.com/hook",
                 "headers" => %{"content-type" => "application/json"}
               })
    end

    test "rejects reserved header key X-WEBHOOK-TIMESTAMP case-insensitively" do
      assert {:error, "headers contains reserved key: x-webhook-timestamp"} =
               Webhook.validate_config(%{
                 "url" => "https://example.com/hook",
                 "headers" => %{"X-WEBHOOK-TIMESTAMP" => "1234"}
               })
    end

    test "rejects reserved header key x-webhook-delivery-id" do
      assert {:error, "headers contains reserved key: x-webhook-delivery-id"} =
               Webhook.validate_config(%{
                 "url" => "https://example.com/hook",
                 "headers" => %{"x-webhook-delivery-id" => "id-1"}
               })
    end

    test "accepts valid custom headers" do
      assert :ok =
               Webhook.validate_config(%{
                 "url" => "https://example.com/hook",
                 "headers" => %{"X-Tenant-Id" => "abc"}
               })
    end

    test "rejects timeout_ms of zero" do
      assert {:error, "timeout_ms must be a positive integer"} =
               Webhook.validate_config(%{"url" => "https://example.com/hook", "timeout_ms" => 0})
    end

    test "rejects timeout_ms of -1" do
      assert {:error, "timeout_ms must be a positive integer"} =
               Webhook.validate_config(%{"url" => "https://example.com/hook", "timeout_ms" => -1})
    end

    test "rejects non-integer timeout_ms" do
      assert {:error, "timeout_ms must be a positive integer"} =
               Webhook.validate_config(%{
                 "url" => "https://example.com/hook",
                 "timeout_ms" => "5000"
               })
    end

    test "accepts timeout_ms of 5000 in valid full config" do
      assert :ok =
               Webhook.validate_config(%{
                 "url" => "https://example.com/hook",
                 "headers" => %{"X-Tenant-Id" => "abc"},
                 "timeout_ms" => 5_000,
                 "max_batch_size" => 10
               })
    end

    test "rejects max_batch_size of zero" do
      assert {:error, "max_batch_size must be a positive integer"} =
               Webhook.validate_config(%{
                 "url" => "https://example.com/hook",
                 "max_batch_size" => 0
               })
    end

    test "rejects max_batch_size of -1" do
      assert {:error, "max_batch_size must be a positive integer"} =
               Webhook.validate_config(%{
                 "url" => "https://example.com/hook",
                 "max_batch_size" => -1
               })
    end

    test "accepts max_batch_size of 10 in valid full config" do
      assert :ok =
               Webhook.validate_config(%{
                 "url" => "https://example.com/hook",
                 "headers" => %{"X-Tenant-Id" => "abc"},
                 "timeout_ms" => 5_000,
                 "max_batch_size" => 10
               })
    end

    test "rejects non-map config" do
      assert {:error, "config must be a map"} = Webhook.validate_config(nil)
      assert {:error, "config must be a map"} = Webhook.validate_config("string")
    end
  end
end
