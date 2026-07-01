defmodule Pageless.Library.Collection do
  use Ecto.Schema
  import Ecto.Changeset

  alias Pageless.Library.{Book, BookCollection, Library}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "collections" do
    field :name, :string
    field :description, :string

    belongs_to :library, Library

    has_many :book_collections, BookCollection, on_replace: :delete

    many_to_many :books, Book,
      join_through: "book_collections",
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(collection, attrs) do
    collection
    |> cast(attrs, [:name, :description, :library_id])
    |> validate_required([:name, :library_id])
    |> unique_constraint([:library_id, :name])
  end
end
