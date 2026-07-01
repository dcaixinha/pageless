defmodule Pageless.Library.LibraryFolder do
  use Ecto.Schema
  import Ecto.Changeset

  alias Pageless.Library.Library

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "library_folders" do
    field :path, :string

    belongs_to :library, Library

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(folder, attrs) do
    folder
    |> cast(attrs, [:path])
    |> validate_required([:path])
    |> update_change(:path, &String.trim/1)
    |> unique_constraint([:library_id, :path])
  end
end
