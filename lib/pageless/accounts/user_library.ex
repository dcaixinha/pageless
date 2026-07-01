defmodule Pageless.Accounts.UserLibrary do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users_libraries" do
    belongs_to :user, Pageless.Accounts.User
    belongs_to :library, Pageless.Library.Library

    timestamps(type: :utc_datetime)
  end

  def changeset(user_library, attrs) do
    user_library
    |> cast(attrs, [:user_id, :library_id])
    |> validate_required([:user_id, :library_id])
    |> unique_constraint([:user_id, :library_id])
  end
end
