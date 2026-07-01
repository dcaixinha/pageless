defmodule Pageless.Library.Library do
  use Ecto.Schema
  import Ecto.Changeset

  alias Pageless.Library.{Book, LibraryFolder}

  @media_types ~w(book)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "libraries" do
    field :name, :string
    field :media_type, :string, default: "book"
    field :store_covers_with_item, :boolean, default: true
    field :store_metadata_with_item, :boolean, default: true
    field :auto_scan_on_file_changes, :boolean, default: true

    has_many :folders, LibraryFolder, on_replace: :delete
    has_many :books, Book

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(library, attrs) do
    library
    |> cast(attrs, [
      :name,
      :media_type,
      :store_covers_with_item,
      :store_metadata_with_item,
      :auto_scan_on_file_changes
    ])
    |> validate_required([:name, :media_type])
    |> validate_inclusion(:media_type, @media_types)
    |> cast_assoc(:folders, with: &LibraryFolder.changeset/2)
  end

  def media_types, do: @media_types
end
