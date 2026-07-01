defmodule Pageless.Repo.Migrations.CreatePlaybackSchema do
  use Ecto.Migration

  def change do
    create table(:playback_progress, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :current_seconds, :float, null: false, default: 0.0
      add :duration_seconds, :float, null: false, default: 0.0
      add :finished_at, :utc_datetime
      add :started_at, :utc_datetime
      add :last_played_at, :utc_datetime
      add :deleted_at, :utc_datetime
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :book_id, references(:books, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:playback_progress, [:user_id, :book_id])
    create index(:playback_progress, [:book_id])

    create table(:bookmarks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :position_seconds, :float, null: false
      add :note, :text
      add :deleted_at, :utc_datetime
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :book_id, references(:books, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:bookmarks, [:user_id, :book_id])

    create table(:listening_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :text
      add :authors, :text
      add :play_method, :string, null: false
      add :device_info, :text, null: false
      add :started_at, :utc_datetime, null: false
      add :updated_at_client, :utc_datetime, null: false
      add :ended_at, :utc_datetime
      add :time_listened_seconds, :bigint, null: false, default: 0
      add :last_position_seconds, :float, null: false, default: 0.0
      add :duration_seconds, :float, null: false, default: 0.0
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :book_id, references(:books, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:listening_sessions, [:user_id, :book_id])
    create index(:listening_sessions, [:book_id])
    create index(:listening_sessions, [:updated_at_client])

    create table(:listening_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :event, :string, null: false
      add :type, :string, null: false, default: "Playback"
      add :position_seconds, :float, null: false, default: 0.0
      add :occurred_at, :utc_datetime, null: false
      add :server_sync_attempted, :boolean, null: false, default: false
      add :server_sync_success, :boolean
      add :server_sync_message, :text
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :book_id, references(:books, type: :binary_id, on_delete: :delete_all), null: false

      add :session_id, references(:listening_sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:listening_events, [:user_id, :book_id])
    create index(:listening_events, [:session_id])
    create index(:listening_events, [:occurred_at])
  end
end
