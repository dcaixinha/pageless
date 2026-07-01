defmodule Pageless.Library.BookSeries do
  use Ecto.Schema
  import Ecto.Changeset

  alias Pageless.Library.{Book, Series}

  @primary_key false
  @foreign_key_type :binary_id
  schema "book_series" do
    belongs_to :book, Book, primary_key: true
    belongs_to :series, Series, primary_key: true
    field :sequence, :string
  end

  @doc false
  def changeset(book_series, attrs) do
    book_series
    |> cast(attrs, [:book_id, :series_id, :sequence])
    |> validate_required([:book_id, :series_id, :sequence])
  end
end
