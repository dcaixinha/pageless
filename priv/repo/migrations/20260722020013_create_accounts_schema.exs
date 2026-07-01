defmodule Pageless.Repo.Migrations.CreateAccountsSchema do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", ""

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :first_name, :string
      add :last_name, :string
      add :email, :citext, null: false
      add :hashed_password, :string
      add :confirmed_at, :utc_datetime
      add :role, :string, null: false, default: "user"
      add :enabled, :boolean, null: false, default: true
      add :last_seen_at, :utc_datetime
      add :player_settings, :map, null: false, default: %{}

      add :permissions, :map,
        null: false,
        default: %{
          "can_download" => true,
          "can_update" => false,
          "can_delete" => false,
          "can_upload" => false,
          "can_access_all_libraries" => true
        }

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])

    create table(:users_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :authenticated_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:users_tokens, [:user_id])
    create unique_index(:users_tokens, [:context, :token])
  end
end
