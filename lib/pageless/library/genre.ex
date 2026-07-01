defmodule Pageless.Library.Genre do
  use Ecto.Schema
  import Ecto.Changeset

  alias Pageless.Library.Book

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "genres" do
    field :name, :string

    many_to_many :books, Book, join_through: "books_genres"

    timestamps(type: :utc_datetime)
  end

  def changeset(genre, attrs) do
    genre
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
