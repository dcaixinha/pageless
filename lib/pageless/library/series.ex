defmodule Pageless.Library.Series do
  use Ecto.Schema
  import Ecto.Changeset

  alias Pageless.Library.{Book, BookSeries}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "series" do
    field :name, :string

    many_to_many :books, Book, join_through: "book_series"
    has_many :book_series, BookSeries

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(series, attrs) do
    series
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
