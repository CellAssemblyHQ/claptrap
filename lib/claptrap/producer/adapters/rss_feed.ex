defmodule Claptrap.Producer.Adapters.RssFeed do
  @moduledoc """
  Materializes pull-mode sink output as an RSS 2.0 feed.

  This adapter implements `Claptrap.Producer.Adapter` for sinks whose type is
  `"rss"`. It is a `:pull` adapter, so producer workers do not push batches to
  an external endpoint. Instead, they trigger feed re-materialization.

  ## Responsibilities

  - Validate RSS sink configuration.
  - Query the catalog for entries currently routed to the sink.
  - Render those entries as RSS 2.0 XML.
  - Store the latest rendered feed in ETS for fast read access.

  ## Data source and storage

  `materialize/2` reads entries using `Catalog.entries_for_sink/2`, honoring
  `config["max_entries"]` when present, or using a default of 50 entries.
  Rendered XML is then stored in the named ETS table `:claptrap_rss_feeds` as:

      {sink_id, {xml, updated_at}}

  `get_feed/1` is the read-side helper for retrieving this in-memory feed.

  ## Implemented behavior

  - Adapter mode is always `:pull`.
  - `push/2` is not supported and returns `{:error, :not_supported}`.
  - `validate_config/1` requires non-empty `"description"` and `"link"` values,
    validates that link is an absolute HTTP(S) URI, and validates
    `"max_entries"` when provided.
  - XML escaping is applied to text fields to keep output well-formed.
  """

  @behaviour Claptrap.Producer.Adapter

  alias Claptrap.Catalog
  alias Claptrap.Catalog.{Entry, Sink}
  alias Claptrap.Producer.Adapters.RssUri

  @ets_table :claptrap_rss_feeds
  @default_max_entries 50

  @impl true
  def mode, do: :pull

  @impl true
  def push(_sink, _entries), do: {:error, :not_supported}

  @impl true
  def materialize(%Sink{} = sink, _entries) do
    max = sink.config["max_entries"] || @default_max_entries
    entries = Catalog.entries_for_sink(sink.id, limit: max)
    xml = build_xml(sink, entries)
    :ets.insert(@ets_table, {sink.id, {xml, DateTime.utc_now()}})
    :ok
  end

  @impl true
  def validate_config(config) when is_map(config) do
    with :ok <- validate_description(config),
         :ok <- validate_link(config) do
      validate_max_entries(config)
    end
  end

  def validate_config(_), do: {:error, "config must be a map"}

  def get_feed(sink_id) do
    case :ets.lookup(@ets_table, sink_id) do
      [{^sink_id, {xml, updated_at}}] -> {:ok, xml, updated_at}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def get_output(sink_id) do
    case get_feed(sink_id) do
      {:ok, xml, _updated_at} -> {:ok, xml, "application/rss+xml"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_xml(%Sink{} = sink, entries) do
    items = Enum.map_join(entries, "\n", &build_item/1)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>#{escape(sink.name)}</title>
        <link>#{escape(channel_link(sink))}</link>
        <description>#{escape(sink.config["description"] || "")}</description>
        <lastBuildDate>#{rfc2822(DateTime.utc_now())}</lastBuildDate>
    #{items}
      </channel>
    </rss>
    """
  end

  defp channel_link(%Sink{config: %{"link" => link}}) when is_binary(link), do: String.trim(link)
  defp channel_link(%Sink{}), do: ""

  defp build_item(%Entry{} = entry) do
    [
      "    <item>",
      "      <title>#{escape(entry.title || "")}</title>",
      maybe_link_tag(entry.url),
      "      <description>#{escape(entry.summary || "")}</description>",
      maybe_author_tag(entry.author),
      maybe_pub_date_tag(entry.published_at),
      "      <guid isPermaLink=\"false\">#{entry.id}</guid>",
      "    </item>"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp escape(nil), do: ""

  defp escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp maybe_link_tag(url) do
    with value when not is_nil(value) <- present_text(url),
         true <- RssUri.valid_with_scheme?(value) do
      "      <link>#{escape(value)}</link>"
    else
      _ -> nil
    end
  end

  defp maybe_author_tag(author) do
    case present_text(author) do
      nil -> nil
      value -> "      <author>#{escape(value)}</author>"
    end
  end

  defp maybe_pub_date_tag(%DateTime{} = dt), do: "      <pubDate>#{rfc2822(dt)}</pubDate>"
  defp maybe_pub_date_tag(_), do: nil

  defp present_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp present_text(_), do: nil

  @day_names ~w(Mon Tue Wed Thu Fri Sat Sun)
  @month_names ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp validate_description(%{"description" => description}) when is_binary(description) do
    if String.trim(description) == "" do
      {:error, "description must be a non-empty string"}
    else
      :ok
    end
  end

  defp validate_description(%{"description" => _}),
    do: {:error, "description must be a non-empty string"}

  defp validate_description(_),
    do: {:error, "missing required key: description"}

  defp validate_link(%{"link" => link}) when is_binary(link) do
    case String.trim(link) do
      "" -> {:error, "link must be a non-empty absolute URI with http or https scheme"}
      trimmed_link -> validate_absolute_http_uri(trimmed_link)
    end
  end

  defp validate_link(%{"link" => _}),
    do: {:error, "link must be a non-empty absolute URI with http or https scheme"}

  defp validate_link(_),
    do: {:error, "missing required key: link"}

  defp validate_absolute_http_uri(link) do
    uri = URI.parse(link)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      :ok
    else
      {:error, "link must be a non-empty absolute URI with http or https scheme"}
    end
  end

  defp validate_max_entries(%{"max_entries" => n}) when not is_integer(n) or n < 1,
    do: {:error, "max_entries must be a positive integer"}

  defp validate_max_entries(_), do: :ok

  defp rfc2822(%DateTime{} = dt) do
    day_name = Enum.at(@day_names, Date.day_of_week(dt) - 1)
    month_name = Enum.at(@month_names, dt.month - 1)

    "#{day_name}, #{String.pad_leading(to_string(dt.day), 2, "0")} #{month_name} #{dt.year} " <>
      "#{String.pad_leading(to_string(dt.hour), 2, "0")}:" <>
      "#{String.pad_leading(to_string(dt.minute), 2, "0")}:" <>
      "#{String.pad_leading(to_string(dt.second), 2, "0")} +0000"
  end
end
