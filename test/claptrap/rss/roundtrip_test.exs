defmodule Claptrap.RSS.RoundtripTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Claptrap.RSS
  alias Claptrap.RSS.{Generators, ParseError}

  # -- Roundtrip property tests -------------------------------------------

  describe "roundtrip: parse(generate(feed)) preserves data" do
    property "entire feed survives roundtrip" do
      check all(feed <- Generators.feed(), max_runs: 100) do
        {:ok, xml} = RSS.generate(feed)
        {:ok, parsed} = RSS.parse(xml)

        assert normalize(parsed) == normalize(feed)
      end
    end
  end

  # -- Adversarial parser tests -------------------------------------------

  describe "adversarial input" do
    test "truncated XML returns error, never raises" do
      result = RSS.parse("<rss><channel><title>Trun")
      assert {:error, %ParseError{}} = result
    end

    test "binary garbage returns error, never raises" do
      result = RSS.parse(<<0xFF, 0xFE, 0x00, 0x01, 0xAB, 0xCD>>)
      assert {:error, %ParseError{}} = result
    end

    test "valid XML but not RSS returns error" do
      html = """
      <?xml version="1.0"?>
      <html><body><p>Not RSS</p></body></html>
      """

      assert {:error, %ParseError{}} = RSS.parse(html)
    end

    test "empty document returns error" do
      assert {:error, %ParseError{}} = RSS.parse("")
    end

    test "nil input returns error" do
      assert {:error, %ParseError{}} = RSS.parse(nil)
    end

    test "large feed with many items completes without hanging" do
      items =
        Enum.map_join(1..1000, "\n", fn i ->
          "<item><title>Item #{i}</title></item>"
        end)

      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0">
        <channel>
          <title>Large Feed</title>
          <link>https://example.com</link>
          <description>A very large feed</description>
          #{items}
        </channel>
      </rss>
      """

      assert {:ok, feed} = RSS.parse(xml)
      assert length(feed.items) == 1000
    end

    property "random binaries never raise, always return ok or error tuple" do
      check all(bin <- binary(min_length: 0, max_length: 500)) do
        result = RSS.parse(bin)
        assert match?({:ok, _}, result) or match?({:error, %ParseError{}}, result)
      end
    end

    property "random printable strings never raise" do
      check all(str <- string(:printable, min_length: 0, max_length: 500)) do
        result = RSS.parse(str)
        assert match?({:ok, _}, result) or match?({:error, %ParseError{}}, result)
      end
    end
  end

  # -- Helpers ------------------------------------------------------------

  defp normalize(%RSS.Feed{} = feed) do
    %{
      feed
      | pub_date: truncate_datetime(feed.pub_date),
        last_build_date: truncate_datetime(feed.last_build_date),
        items: Enum.map(feed.items, &normalize/1)
    }
  end

  defp normalize(%RSS.Item{} = item) do
    %{item | pub_date: truncate_datetime(item.pub_date)}
  end

  defp truncate_datetime(nil), do: nil
  defp truncate_datetime(%DateTime{} = dt), do: DateTime.truncate(dt, :second)
end
