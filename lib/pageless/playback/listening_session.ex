defmodule Pageless.Playback.ListeningSession do
  use Ecto.Schema
  import Ecto.Changeset

  alias Pageless.Accounts.User
  alias Pageless.Library.Book
  alias Pageless.Playback.ListeningEvent

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "listening_sessions" do
    field :title, :string
    field :authors, :string
    field :play_method, :string
    field :device_info, :string
    field :started_at, :utc_datetime
    field :updated_at_client, :utc_datetime
    field :ended_at, :utc_datetime
    field :time_listened_seconds, :integer, default: 0
    field :last_position_seconds, :float, default: 0.0
    field :duration_seconds, :float, default: 0.0

    belongs_to :user, User
    belongs_to :book, Book
    has_many :events, ListeningEvent, foreign_key: :session_id

    timestamps(type: :utc_datetime)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :id,
      :user_id,
      :book_id,
      :title,
      :authors,
      :play_method,
      :device_info,
      :started_at,
      :updated_at_client,
      :ended_at,
      :time_listened_seconds,
      :last_position_seconds,
      :duration_seconds
    ])
    |> validate_required([
      :id,
      :user_id,
      :book_id,
      :play_method,
      :device_info,
      :started_at,
      :updated_at_client
    ])
    |> validate_number(:time_listened_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:last_position_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:duration_seconds, greater_than_or_equal_to: 0)
  end
end
