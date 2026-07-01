defmodule Pageless.Library.Narrator do
  use Ecto.Schema
  import Ecto.Changeset

  alias Pageless.Library.BookNarrator

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "narrators" do
    field :name, :string

    has_many :book_narrators, BookNarrator
    has_many :books, through: [:book_narrators, :book]

    timestamps(type: :utc_datetime)
  end

  def changeset(narrator, attrs) do
    narrator
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> unique_constraint(:name, name: :narrators_name_ci_index)
  end
end
