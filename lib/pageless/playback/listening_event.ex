defmodule Pageless.Playback.ListeningEvent do
  use Ecto.Schema
  import Ecto.Changeset

  alias Pageless.Accounts.User
  alias Pageless.Library.Book
  alias Pageless.Playback.ListeningSession

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "listening_events" do
    field :event, :string
    field :type, :string, default: "Playback"
    field :position_seconds, :float, default: 0.0
    field :occurred_at, :utc_datetime
    field :server_sync_attempted, :boolean, default: false
    field :server_sync_success, :boolean
    field :server_sync_message, :string

    belongs_to :user, User
    belongs_to :book, Book
    belongs_to :session, ListeningSession

    timestamps(type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :id,
      :user_id,
      :book_id,
      :session_id,
      :event,
      :type,
      :position_seconds,
      :occurred_at,
      :server_sync_attempted,
      :server_sync_success,
      :server_sync_message
    ])
    |> validate_required([:id, :user_id, :book_id, :session_id, :event, :type, :occurred_at])
    |> validate_number(:position_seconds, greater_than_or_equal_to: 0)
    |> validate_length(:event, max: 64)
    |> validate_length(:type, max: 64)
    |> validate_length(:server_sync_message, max: 500)
  end
end
