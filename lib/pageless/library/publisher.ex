defmodule Pageless.Library.Publisher do
  use Ecto.Schema
  import Ecto.Changeset

  alias Pageless.Library.Book

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "publishers" do
    field :name, :string

    has_many :books, Book

    timestamps(type: :utc_datetime)
  end

  def changeset(publisher, attrs) do
    publisher
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> unique_constraint(:name, name: :publishers_name_ci_index)
  end
end
