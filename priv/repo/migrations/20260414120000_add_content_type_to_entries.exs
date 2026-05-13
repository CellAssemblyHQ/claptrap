defmodule Claptrap.Repo.Migrations.AddContentTypeToEntries do
  use Ecto.Migration

  def change do
    alter table(:entries) do
      add :content_type, :string
    end
  end
end
