defmodule Claptrap.Catalog.Entry do
  @moduledoc """
  Ecto schema for normalized content records.

  Entries represent consumed items in Claptrap's internal model. Each entry
  belongs to a source, can have many artifacts, and stores normalized metadata
  such as title, URL, author, publication time, tags, and lifecycle status.

  The changeset requires `source_id`, `external_id`, `title`, and `status`.
  Status is constrained to `unread`, `in_progress`, `read`, or `archived`, and
  `external_id` is unique per source.

  Free-form text fields have product-level length caps enforced in the
  changeset (see `@max_lengths`). The underlying columns are `:text` and have
  no DB-level cap; the changeset is the single source of truth for what counts
  as a valid entry. Limits are deliberately generous — they exist to catch
  upstream bugs (e.g. an adapter stuffing an HTML body into `:title`) and
  runaway input, not to enforce display widths.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @max_lengths %{
    external_id: 512,
    title: 1_024,
    url: 4_096,
    author: 256,
    summary: 16_384
  }

  schema "entries" do
    field :external_id, :string
    field :title, :string
    field :summary, :string
    field :url, :string
    field :content_type, :string
    field :author, :string
    field :published_at, :utc_datetime_usec
    field :status, :string
    field :metadata, :map
    field :tags, {:array, :string}, default: []

    has_many :artifacts, Claptrap.Catalog.Artifact
    belongs_to :source, Claptrap.Catalog.Source

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :source_id,
      :external_id,
      :title,
      :summary,
      :url,
      :content_type,
      :author,
      :published_at,
      :status,
      :metadata,
      :tags
    ])
    |> validate_required([:source_id, :external_id, :title, :status])
    |> validate_inclusion(:status, ["unread", "in_progress", "read", "archived"])
    |> validate_lengths()
    |> unique_constraint([:external_id, :source_id])
  end

  defp validate_lengths(changeset) do
    Enum.reduce(@max_lengths, changeset, fn {field, max}, acc ->
      validate_length(acc, field, max: max)
    end)
  end
end
