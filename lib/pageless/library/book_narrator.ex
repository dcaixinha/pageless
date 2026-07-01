defmodule Pageless.Library.BookNarrator do
  use Ecto.Schema
  import Ecto.Changeset

  alias Pageless.Library.{Book, Narrator}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "book_narrators" do
    belongs_to :book, Book
    belongs_to :narrator, Narrator
    field :position, :integer
  end

  def changeset(book_narrator, attrs) do
    book_narrator
    |> cast(attrs, [:book_id, :narrator_id, :position])
    |> validate_required([:book_id, :narrator_id, :position])
    |> validate_number(:position, greater_than_or_equal_to: 0)
  end
end
