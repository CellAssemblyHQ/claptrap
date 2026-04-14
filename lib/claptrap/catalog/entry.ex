defmodule Claptrap.Catalog.Entry do
  @moduledoc """
  Ecto schema for normalized content records.

  Entries represent consumed items in Claptrap's internal model. Each entry
  belongs to a source, can have many artifacts, and stores normalized metadata
  such as title, URL, author, publication time, tags, and lifecycle status.

  The changeset requires `source_id`, `external_id`, `title`, and `status`.
  Status is constrained to `unread`, `in_progress`, `read`, or `archived`, and
  `external_id` is unique per source.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

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
    |> unique_constraint([:external_id, :source_id])
  end
end
