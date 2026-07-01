defmodule Pageless.Playback.Bookmark do
  use Ecto.Schema
  import Ecto.Changeset

  alias Pageless.Accounts.User
  alias Pageless.Library.Book

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "bookmarks" do
    field :position_seconds, :float
    field :note, :string
    field :deleted_at, :utc_datetime

    belongs_to :user, User
    belongs_to :book, Book

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(bookmark, attrs) do
    bookmark
    |> cast(attrs, [:position_seconds, :note])
    |> validate_required([:position_seconds])
    |> validate_number(:position_seconds, greater_than_or_equal_to: 0)
    |> validate_length(:note, max: 500)
  end
end
