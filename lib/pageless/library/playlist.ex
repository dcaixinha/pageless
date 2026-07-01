defmodule Pageless.Library.Playlist do
  use Ecto.Schema
  import Ecto.Changeset

  alias Pageless.Accounts.User
  alias Pageless.Library.{Book, PlaylistBook}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "playlists" do
    field :name, :string
    field :description, :string

    belongs_to :user, User

    has_many :playlist_books, PlaylistBook, on_replace: :delete

    many_to_many :books, Book,
      join_through: "playlist_books",
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(playlist, attrs) do
    playlist
    |> cast(attrs, [:name, :description, :user_id])
    |> validate_required([:name, :user_id])
    |> unique_constraint([:user_id, :name])
  end
end
