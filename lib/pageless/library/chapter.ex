defmodule Pageless.Library.Chapter do
  use Ecto.Schema
  import Ecto.Changeset

  alias Pageless.Library.Book

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "chapters" do
    field :title, :string
    field :start_seconds, :float
    field :end_seconds, :float
    field :index, :integer, default: 0

    belongs_to :book, Book

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(chapter, attrs) do
    chapter
    |> cast(attrs, [:title, :start_seconds, :end_seconds, :index])
    |> validate_required([:start_seconds, :end_seconds, :index])
  end
end
