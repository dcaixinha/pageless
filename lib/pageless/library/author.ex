defmodule Pageless.Library.Author do
  use Ecto.Schema
  import Ecto.Changeset

  alias Pageless.Library.Book

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "authors" do
    field :name, :string

    many_to_many :books, Book, join_through: "books_authors"

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(author, attrs) do
    author
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
