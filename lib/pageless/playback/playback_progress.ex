defmodule Pageless.Playback.PlaybackProgress do
  use Ecto.Schema
  import Ecto.Changeset

  alias Pageless.Accounts.User
  alias Pageless.Library.Book

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "playback_progress" do
    field :current_seconds, :float, default: 0.0
    field :duration_seconds, :float, default: 0.0
    field :finished_at, :utc_datetime
    field :started_at, :utc_datetime
    field :last_played_at, :utc_datetime
    field :deleted_at, :utc_datetime

    belongs_to :user, User
    belongs_to :book, Book

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(progress, attrs) do
    progress
    |> cast(attrs, [
      :current_seconds,
      :duration_seconds,
      :finished_at,
      :started_at,
      :last_played_at
    ])
    |> validate_required([:current_seconds])
    |> validate_number(:current_seconds, greater_than_or_equal_to: 0)
  end
end
