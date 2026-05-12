defmodule Claptrap.Repo.Migrations.WidenEntryTextFields do
  use Ecto.Migration

  @moduledoc """
  Drop the implicit `varchar(255)` cap from entry text fields.

  Real-world feed items routinely exceed 255 chars in `url` and `summary`,
  and occasionally in `title` and `external_id`. The previous `:string`
  columns caused Postgrex 22001 errors to escape `Catalog.create_entry/1`
  as raises, which in turn crash-looped `Claptrap.Consumer.Worker`.

  After this migration, sensible upper bounds are enforced in
  `Claptrap.Catalog.Entry`'s changeset rather than by the column type.
  `status` is intentionally left as `:string` since it is constrained to a
  fixed enum by `validate_inclusion/3`.
  """

  def change do
    alter table(:entries) do
      modify :external_id, :text, from: :string
      modify :title, :text, from: :string
      modify :summary, :text, from: :string
      modify :url, :text, from: :string
      modify :author, :text, from: :string
    end
  end
end
