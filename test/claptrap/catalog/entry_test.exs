defmodule Claptrap.Catalog.EntryTest do
  use Claptrap.DataCase, async: true

  @moduletag :integration
  @moduletag capture_log: true

  alias Claptrap.Catalog.Entry

  @valid_attrs %{
    source_id: "00000000-0000-0000-0000-000000000001",
    external_id: "ext-123",
    title: "Test Entry",
    status: "unread"
  }

  describe "changeset/2" do
    test "valid attributes" do
      changeset = Entry.changeset(%Entry{}, @valid_attrs)
      assert changeset.valid?
    end

    test "requires source_id" do
      changeset = Entry.changeset(%Entry{}, Map.delete(@valid_attrs, :source_id))
      assert %{source_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires external_id" do
      changeset = Entry.changeset(%Entry{}, Map.delete(@valid_attrs, :external_id))
      assert %{external_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires title" do
      changeset = Entry.changeset(%Entry{}, Map.delete(@valid_attrs, :title))
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires status" do
      changeset = Entry.changeset(%Entry{}, Map.delete(@valid_attrs, :status))
      assert %{status: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects invalid status" do
      changeset = Entry.changeset(%Entry{}, %{@valid_attrs | status: "invalid"})
      assert %{status: [_]} = errors_on(changeset)
    end

    test "accepts all valid statuses" do
      for status <- ["unread", "in_progress", "read", "archived"] do
        changeset = Entry.changeset(%Entry{}, %{@valid_attrs | status: status})
        assert changeset.valid?, "expected status #{status} to be valid"
      end
    end

    test "rejects oversize text fields" do
      # Regression guard for the staging crash loop in which a long upstream
      # `url` raised Postgrex 22001 out of `Catalog.create_entry/1` instead of
      # returning `{:error, changeset}`. The changeset is now the source of
      # truth for length limits; the columns are unbounded `:text`.
      cases = [
        {:external_id, 513},
        {:title, 1_025},
        {:url, 4_097},
        {:author, 257},
        {:summary, 16_385}
      ]

      for {field, len} <- cases do
        attrs = Map.put(@valid_attrs, field, String.duplicate("x", len))
        changeset = Entry.changeset(%Entry{}, attrs)

        refute changeset.valid?, "expected #{field} of length #{len} to be invalid"
        assert %{^field => [message | _]} = errors_on(changeset)
        assert message =~ "should be at most"
      end
    end

    test "optional fields are accepted" do
      attrs =
        Map.merge(@valid_attrs, %{
          summary: "A summary",
          url: "https://example.com",
          author: "Author",
          metadata: %{"key" => "value"},
          tags: ["tag1"]
        })

      changeset = Entry.changeset(%Entry{}, attrs)
      assert changeset.valid?
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
