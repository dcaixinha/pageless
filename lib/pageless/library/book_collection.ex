defmodule Pageless.Library.BookCollection do
  use Ecto.Schema
  import Ecto.Changeset

  alias Pageless.Library.{Book, Collection}

  @primary_key false
  @foreign_key_type :binary_id
  schema "book_collections" do
    belongs_to :book, Book, primary_key: true
    belongs_to :collection, Collection, primary_key: true
    field :position, :integer, default: 0
  end

  @doc false
  def changeset(book_collection, attrs) do
    book_collection
    |> cast(attrs, [:book_id, :collection_id, :position])
    |> validate_required([:book_id, :collection_id])
  end
end
