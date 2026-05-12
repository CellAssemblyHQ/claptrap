defmodule Claptrap.RSS.Generators do
  @moduledoc false

  use ExUnitProperties

  alias Claptrap.RSS.{Category, Cloud, Enclosure, Feed, Guid, Image, Item, Source, TextInput}

  @valid_days ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
  @valid_cloud_protocols ~w(xml-rpc soap http-post)

  # -- Public generators --------------------------------------------------

  def feed do
    gen all(
          title <- xml_safe_string(),
          link <- url(),
          description <- xml_safe_string(),
          items <- list_of(item(), max_length: 5),
          categories <- list_of(category(), max_length: 3),
          language <- optional(member_of(["en-us", "fr", "de", "ja", "es"])),
          copyright <- optional(xml_safe_string()),
          managing_editor <- optional(email()),
          web_master <- optional(email()),
          pub_date <- optional(datetime()),
          last_build_date <- optional(datetime()),
          generator_field <- optional(xml_safe_string()),
          docs <- optional(url()),
          ttl <- optional(integer(0..1440)),
          rating <- optional(xml_safe_string()),
          cloud <- optional(cloud()),
          image <- optional(image(constant(link))),
          text_input <- optional(text_input(constant(link))),
          skip_hours <- skip_hours(),
          skip_days <- skip_days()
        ) do
      %Feed{
        title: title,
        link: link,
        description: description,
        items: items,
        categories: categories,
        language: language,
        copyright: copyright,
        managing_editor: managing_editor,
        web_master: web_master,
        pub_date: pub_date,
        last_build_date: last_build_date,
        generator: generator_field,
        docs: docs,
        ttl: ttl,
        rating: rating,
        cloud: cloud,
        image: image,
        text_input: text_input,
        skip_hours: skip_hours,
        skip_days: skip_days,
        namespaces: %{},
        extensions: %{}
      }
    end
  end

  def item do
    gen all(
          has_title <- boolean(),
          title <- xml_safe_string(),
          description <- xml_safe_string(),
          link <- optional(url()),
          author <- optional(email()),
          comments <- optional(url()),
          pub_date <- optional(datetime()),
          enclosure <- optional(enclosure()),
          guid <- optional(guid()),
          source <- optional(source()),
          categories <- list_of(category(), max_length: 3)
        ) do
      %Item{
        title: if(has_title, do: title, else: nil),
        description: if(has_title, do: nil, else: description),
        link: link,
        author: author,
        comments: comments,
        pub_date: pub_date,
        enclosure: enclosure,
        guid: guid,
        source: source,
        categories: categories,
        extensions: %{}
      }
    end
  end

  def category do
    gen all(
          value <- xml_safe_string(),
          domain <- optional(url())
        ) do
      %Category{value: value, domain: domain}
    end
  end

  def enclosure do
    gen all(
          url <- url(),
          length <- integer(0..100_000_000),
          type <- member_of(["audio/mpeg", "video/mp4", "application/pdf", "image/jpeg"])
        ) do
      %Enclosure{url: url, length: length, type: type}
    end
  end

  def guid do
    gen all(
          is_perma_link <- boolean(),
          value <- if(is_perma_link, do: url(), else: xml_safe_string())
        ) do
      %Guid{value: value, is_perma_link: is_perma_link}
    end
  end

  def image(feed_link \\ constant("https://example.com")) do
    gen all(
          img_url <- url(),
          title <- xml_safe_string(),
          link <- feed_link,
          width <- optional(integer(1..144)),
          height <- optional(integer(1..400)),
          description <- optional(xml_safe_string())
        ) do
      %Image{
        url: img_url,
        title: title,
        link: link,
        width: width,
        height: height,
        description: description
      }
    end
  end

  def cloud do
    gen all(
          domain <- domain_name(),
          port <- integer(1..65_535),
          path <- map(xml_safe_string(), &"/#{&1}"),
          register_procedure <- xml_safe_string(),
          protocol <- member_of(@valid_cloud_protocols)
        ) do
      %Cloud{
        domain: domain,
        port: port,
        path: path,
        register_procedure: register_procedure,
        protocol: protocol
      }
    end
  end

  def source do
    gen all(
          value <- xml_safe_string(),
          url <- url()
        ) do
      %Source{value: value, url: url}
    end
  end

  def text_input(feed_link \\ constant("https://example.com")) do
    gen all(
          title <- xml_safe_string(),
          description <- xml_safe_string(),
          name <- xml_safe_string(),
          link <- feed_link
        ) do
      %TextInput{title: title, description: description, name: name, link: link}
    end
  end

  # -- Primitive generators -----------------------------------------------

  def url do
    gen all(
          scheme <- member_of(["https", "http"]),
          domain <- domain_name(),
          path_segment <- string(:alphanumeric, min_length: 1, max_length: 10)
        ) do
      "#{scheme}://#{domain}/#{path_segment}"
    end
  end

  def datetime do
    gen all(
          year <- integer(2000..2030),
          month <- integer(1..12),
          day <- integer(1..28),
          hour <- integer(0..23),
          minute <- integer(0..59),
          second <- integer(0..59)
        ) do
      {:ok, naive} = NaiveDateTime.new(year, month, day, hour, minute, second)
      {:ok, dt} = DateTime.from_naive(naive, "Etc/UTC")
      dt
    end
  end

  def email do
    gen all(
          user <- string(:alphanumeric, min_length: 1, max_length: 8),
          domain <- domain_name()
        ) do
      "#{user}@#{domain}"
    end
  end

  # -- Private helpers ----------------------------------------------------

  defp xml_safe_string do
    gen all(s <- string(:alphanumeric, min_length: 1, max_length: 30)) do
      s
    end
  end

  defp domain_name do
    gen all(
          name <- string(:alphanumeric, min_length: 1, max_length: 10),
          tld <- member_of(["com", "org", "net", "io"])
        ) do
      "#{name}.#{tld}"
    end
  end

  defp optional(gen) do
    one_of([constant(nil), gen])
  end

  defp skip_hours do
    gen all(hours <- uniq_list_of(integer(0..23), max_length: 4)) do
      hours
    end
  end

  defp skip_days do
    gen all(days <- uniq_list_of(member_of(@valid_days), max_length: 3)) do
      days
    end
  end
end
