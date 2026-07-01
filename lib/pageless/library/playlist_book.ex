defmodule Pageless.Library.PlaylistBook do
  use Ecto.Schema
  import Ecto.Changeset

  alias Pageless.Library.{Book, Playlist}

  @primary_key false
  @foreign_key_type :binary_id
  schema "playlist_books" do
    belongs_to :playlist, Playlist, primary_key: true
    belongs_to :book, Book, primary_key: true
    field :position, :integer, default: 0
  end

  @doc false
  def changeset(playlist_book, attrs) do
    playlist_book
    |> cast(attrs, [:playlist_id, :book_id, :position])
    |> validate_required([:playlist_id, :book_id])
  end
end
