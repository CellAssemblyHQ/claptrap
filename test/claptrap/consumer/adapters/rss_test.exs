defmodule Claptrap.Consumer.Adapters.RSSTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Claptrap.Catalog.Source
  alias Claptrap.Consumer.Adapters.RSS

  setup do
    Req.Test.set_req_test_to_shared()

    previous_options = Application.get_env(:claptrap, :rss_req_options, [])
    Application.put_env(:claptrap, :rss_req_options, plug: {Req.Test, RSS})

    on_exit(fn -> Application.put_env(:claptrap, :rss_req_options, previous_options) end)

    :ok
  end

  describe "validate_config/1" do
    test "accepts a config with a url" do
      assert :ok = RSS.validate_config(%{"url" => "https://example.com/feed.xml"})
    end

    test "rejects a config without a url" do
      assert {:error, _reason} = RSS.validate_config(%{})
    end
  end

  describe "fetch/1" do
    test "returns normalized attrs for an RSS 2.0 feed" do
      Req.Test.expect(RSS, fn conn ->
        send_resp(conn, 200, rss_feed())
      end)

      assert {:ok, [entry]} = RSS.fetch(source())
      assert entry.external_id == "guid-1"
      assert entry.title == "First post"
      assert entry.summary == "A summary"
      assert entry.url == "https://example.com/posts/1"
      assert entry.author == "Ada Lovelace"
      assert entry.tags == ["elixir", "otp"]
      assert %DateTime{} = entry.published_at
    end

    test "normalizes RFC 822 numeric offsets to UTC" do
      Req.Test.expect(RSS, fn conn ->
        send_resp(conn, 200, offset_rss_feed())
      end)

      assert {:ok, [entry]} = RSS.fetch(source())
      assert entry.published_at == ~U[2026-03-18 02:30:00Z]
    end

    test "accepts RFC 822 dates without seconds" do
      Req.Test.expect(RSS, fn conn ->
        send_resp(conn, 200, no_seconds_rss_feed())
      end)

      assert {:ok, [entry]} = RSS.fetch(source())
      assert entry.published_at == ~U[2026-03-18 12:00:00Z]
    end

    test "returns transient errors for 500 responses" do
      Req.Test.expect(RSS, fn conn ->
        send_resp(conn, 500, "boom")
      end)

      assert {:error, {:http_error, 500}} = RSS.fetch(source())
    end

    @tag capture_log: true
    test "raises on malformed xml" do
      Req.Test.expect(RSS, fn conn ->
        send_resp(conn, 200, "<rss><channel><item></rss>")
      end)

      assert_raise ArgumentError, ~r/unable to parse RSS feed/, fn ->
        RSS.fetch(source())
      end
    end

    test "fills optional fields with nil or defaults" do
      Req.Test.expect(RSS, fn conn ->
        send_resp(conn, 200, minimal_rss_feed())
      end)

      assert {:ok, [entry]} = RSS.fetch(source())
      assert entry.title == "(untitled)"
      assert entry.summary == nil
      assert entry.url == "https://example.com/minimal"
      assert entry.author == nil
      assert entry.published_at == nil
      assert entry.tags == []
    end

    test "keeps lenient behavior for malformed item pubDate" do
      Req.Test.expect(RSS, fn conn ->
        send_resp(conn, 200, malformed_item_pubdate_feed())
      end)

      assert {:ok, [entry]} = RSS.fetch(source())
      assert entry.external_id == "guid-bad-date"
      assert entry.title == "Bad Date Post"
      assert entry.published_at == nil
    end

    test "lenient parser drops malformed integer fields and still normalizes items" do
      Req.Test.expect(RSS, fn conn ->
        send_resp(conn, 200, malformed_integer_fields_feed())
      end)

      assert {:ok, [entry]} = RSS.fetch(source())
      assert entry.external_id == "guid-malformed"
      assert entry.title == "Post survives malformed numeric fields"
      assert entry.url == "https://example.com/posts/malformed"
      assert entry.tags == []
    end

    test "derives external_id from title hash when guid and link are absent" do
      Req.Test.expect(RSS, fn conn ->
        send_resp(conn, 200, no_guid_no_link_feed())
      end)

      assert {:ok, [entry]} = RSS.fetch(source())
      assert is_binary(entry.external_id)
      assert byte_size(entry.external_id) == 64
      assert entry.title == "Hashable post"
    end

    test "raises when item has no identifiable fields" do
      Req.Test.expect(RSS, fn conn ->
        send_resp(conn, 200, empty_item_feed())
      end)

      assert_raise ArgumentError,
                   ~r/missing a stable identifier/,
                   fn -> RSS.fetch(source()) end
    end

    test "returns transient error for 429 responses" do
      Req.Test.expect(RSS, fn conn ->
        send_resp(conn, 429, "too many requests")
      end)

      assert {:error, {:http_error, 429}} = RSS.fetch(source())
    end

    test "returns transient error for 408 responses" do
      Req.Test.expect(RSS, fn conn ->
        send_resp(conn, 408, "request timeout")
      end)

      assert {:error, {:http_error, 408}} = RSS.fetch(source())
    end

    test "raises on non-retriable 4xx responses" do
      Req.Test.expect(RSS, fn conn ->
        send_resp(conn, 404, "not found")
      end)

      assert_raise ArgumentError,
                   ~r/non-retriable/,
                   fn -> RSS.fetch(source()) end
    end

    test "returns transient error for transport failures" do
      Req.Test.expect(RSS, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, :econnrefused} = RSS.fetch(source())
    end
  end

  describe "ingest/2" do
    test "returns unsupported for push-mode inputs" do
      assert {:error, :unsupported} = RSS.ingest(source(), {:email, self(), %{}})
    end
  end

  defp source(config \\ %{"url" => "https://example.com/feed.xml"}) do
    %Source{id: Ecto.UUID.generate(), type: "rss", name: "Feed", config: config, tags: []}
  end

  defp rss_feed do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Example Feed</title>
        <item>
          <guid>guid-1</guid>
          <title>First post</title>
          <description>A summary</description>
          <link>https://example.com/posts/1</link>
          <author>Ada Lovelace</author>
          <pubDate>Tue, 18 Mar 2026 00:00:00 GMT</pubDate>
          <category>elixir</category>
          <category>otp</category>
        </item>
      </channel>
    </rss>
    """
  end

  defp offset_rss_feed do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Offset Feed</title>
        <item>
          <guid>guid-offset</guid>
          <title>Offset post</title>
          <link>https://example.com/offset</link>
          <pubDate>Tue, 18 Mar 2026 00:30:00 -0200</pubDate>
        </item>
      </channel>
    </rss>
    """
  end

  defp no_seconds_rss_feed do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>No Seconds Feed</title>
        <item>
          <guid>guid-no-seconds</guid>
          <title>No Seconds</title>
          <link>https://example.com/no-seconds</link>
          <pubDate>Tue, 18 Mar 2026 12:00 +0000</pubDate>
        </item>
      </channel>
    </rss>
    """
  end

  defp minimal_rss_feed do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Minimal Feed</title>
        <item>
          <link>https://example.com/minimal</link>
        </item>
      </channel>
    </rss>
    """
  end

  defp malformed_integer_fields_feed do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Malformed Numeric Feed</title>
        <link>https://example.com</link>
        <description>Malformed integer fields should not break lenient parsing</description>
        <ttl>60oops</ttl>
        <cloud domain="rpc.example.com" port="80oops" path="/RPC2"
               registerProcedure="myCloud.rssPleaseNotify" protocol="xml-rpc"/>
        <skipHours><hour>12x</hour></skipHours>
        <item>
          <guid>guid-malformed</guid>
          <title>Post survives malformed numeric fields</title>
          <link>https://example.com/posts/malformed</link>
          <enclosure url="https://example.com/audio.mp3" length="1000bytes" type="audio/mpeg"/>
        </item>
      </channel>
    </rss>
    """
  end

  defp no_guid_no_link_feed do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Hash ID Feed</title>
        <item>
          <title>Hashable post</title>
          <description>Content for hashing</description>
        </item>
      </channel>
    </rss>
    """
  end

  defp empty_item_feed do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Empty Item Feed</title>
        <item></item>
      </channel>
    </rss>
    """
  end

  defp malformed_item_pubdate_feed do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Malformed Item Date Feed</title>
        <item>
          <guid>guid-bad-date</guid>
          <title>Bad Date Post</title>
          <link>https://example.com/bad-date</link>
          <pubDate>not-a-date</pubDate>
        </item>
      </channel>
    </rss>
    """
  end
end
