defmodule Claptrap.API.Handlers.SinksTest do
  use Claptrap.DataCase, async: true

  @moduletag :integration
  @moduletag capture_log: true

  alias Claptrap.API.Plug, as: APIPlug
  alias Claptrap.Catalog
  alias Claptrap.Producer.Adapters.RssFeed

  @sink_attrs %{type: "webhook", name: "Hook", config: %{"url" => "https://example.com/hook"}}
  @rss_sink_attrs %{
    type: "rss",
    name: "My Feed",
    config: %{"description" => "A test feed", "link" => "https://example.com/my-feed"}
  }

  defp call(method, path, body \\ nil) do
    call_with_headers(method, path, [{"authorization", "Bearer test-api-key"}], body)
  end

  defp call_with_headers(method, path, headers, body \\ nil) do
    conn = Plug.Test.conn(method, path)

    conn =
      Enum.reduce(headers, conn, fn {header, value}, acc ->
        Plug.Conn.put_req_header(acc, header, value)
      end)

    conn =
      if body do
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Map.put(:body_params, body)
      else
        conn
      end

    APIPlug.call(conn, APIPlug.init([]))
  end

  describe "GET /api/v1/sinks" do
    test "returns empty list" do
      conn = call(:get, "/api/v1/sinks")
      assert conn.status == 200
      assert %{"items" => []} = Jason.decode!(conn.resp_body)
    end

    test "returns sinks" do
      {:ok, _} = Catalog.create_sink(@sink_attrs)
      conn = call(:get, "/api/v1/sinks")
      assert conn.status == 200
      assert %{"items" => [%{"type" => "webhook"}]} = Jason.decode!(conn.resp_body)
    end

    test "paginates with page_size and page_token" do
      for i <- 1..3 do
        {:ok, _} = Catalog.create_sink(%{@sink_attrs | name: "Hook #{i}"})
      end

      conn = call(:get, "/api/v1/sinks?page_size=2")
      body = Jason.decode!(conn.resp_body)
      assert length(body["items"]) == 2
      assert body["next_page_token"]

      conn = call(:get, "/api/v1/sinks?page_size=2&page_token=#{body["next_page_token"]}")
      body = Jason.decode!(conn.resp_body)
      assert length(body["items"]) == 1
      refute Map.has_key?(body, "next_page_token")
    end
  end

  describe "POST /api/v1/sinks" do
    test "creates a sink with valid params" do
      conn =
        call(:post, "/api/v1/sinks", %{
          "type" => "webhook",
          "name" => "Hook",
          "config" => %{"url" => "https://example.com"}
        })

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      assert body["type"] == "webhook"
      refute Map.has_key?(body, "credentials")
    end

    test "returns 422 with invalid params" do
      conn = call(:post, "/api/v1/sinks", %{})
      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["errors"]
    end
  end

  describe "GET /api/v1/sinks/:id" do
    test "returns a sink" do
      {:ok, sink} = Catalog.create_sink(@sink_attrs)
      conn = call(:get, "/api/v1/sinks/#{sink.id}")
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["id"] == sink.id
    end

    test "returns 404 for missing sink" do
      conn = call(:get, "/api/v1/sinks/#{Ecto.UUID.generate()}")
      assert conn.status == 404
    end

    test "returns 400 for malformed UUID" do
      conn = call(:get, "/api/v1/sinks/not-a-uuid")
      assert conn.status == 400
    end
  end

  describe "GET /api/v1/sinks/:id content negotiation" do
    test "returns RSS output when requested and materialized" do
      {:ok, sink} = Catalog.create_sink(@rss_sink_attrs)
      assert :ok = RssFeed.materialize(sink, [])

      conn =
        call_with_headers(
          :get,
          "/api/v1/sinks/#{sink.id}",
          [
            {"authorization", "Bearer test-api-key"},
            {"accept", "application/rss+xml"}
          ]
        )

      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/rss+xml; charset=utf-8"]
      assert conn.resp_body =~ "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    end

    test "keeps JSON response when Accept header is missing" do
      {:ok, sink} = Catalog.create_sink(@rss_sink_attrs)
      assert :ok = RssFeed.materialize(sink, [])

      conn = call(:get, "/api/v1/sinks/#{sink.id}")

      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      assert Jason.decode!(conn.resp_body)["id"] == sink.id
    end

    test "returns 406 when requesting RSS from unsupported sink type" do
      {:ok, sink} = Catalog.create_sink(@sink_attrs)

      conn =
        call_with_headers(
          :get,
          "/api/v1/sinks/#{sink.id}",
          [
            {"authorization", "Bearer test-api-key"},
            {"accept", "application/rss+xml"}
          ]
        )

      assert conn.status == 406
      assert Jason.decode!(conn.resp_body) == %{"error" => "not acceptable"}
    end

    test "returns 404 when RSS output is not materialized yet" do
      {:ok, sink} = Catalog.create_sink(Map.put(@rss_sink_attrs, :enabled, false))

      conn =
        call_with_headers(
          :get,
          "/api/v1/sinks/#{sink.id}",
          [
            {"authorization", "Bearer test-api-key"},
            {"accept", "application/rss+xml"}
          ]
        )

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body) == %{"error" => "not found"}
    end

    test "bypasses auth for RSS output requests" do
      {:ok, sink} = Catalog.create_sink(@rss_sink_attrs)
      assert :ok = RssFeed.materialize(sink, [])

      conn =
        call_with_headers(
          :get,
          "/api/v1/sinks/#{sink.id}",
          [{"accept", "application/rss+xml"}]
        )

      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/rss+xml; charset=utf-8"]
    end

    test "still requires auth for JSON output requests" do
      {:ok, sink} = Catalog.create_sink(@rss_sink_attrs)

      conn =
        call_with_headers(
          :get,
          "/api/v1/sinks/#{sink.id}",
          [{"accept", "application/json"}]
        )

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
    end
  end

  describe "PATCH /api/v1/sinks/:id" do
    test "updates a sink" do
      {:ok, sink} = Catalog.create_sink(@sink_attrs)
      conn = call(:patch, "/api/v1/sinks/#{sink.id}", %{"name" => "Updated"})
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["name"] == "Updated"
    end

    test "returns 422 with invalid params" do
      {:ok, sink} = Catalog.create_sink(@sink_attrs)
      conn = call(:patch, "/api/v1/sinks/#{sink.id}", %{"name" => ""})
      assert conn.status == 422
    end
  end

  describe "DELETE /api/v1/sinks/:id" do
    test "deletes a sink" do
      {:ok, sink} = Catalog.create_sink(@sink_attrs)
      conn = call(:delete, "/api/v1/sinks/#{sink.id}")
      assert conn.status == 204
      assert Catalog.list_sinks() == []
    end

    test "returns 404 for missing sink" do
      conn = call(:delete, "/api/v1/sinks/#{Ecto.UUID.generate()}")
      assert conn.status == 404
    end
  end
end
