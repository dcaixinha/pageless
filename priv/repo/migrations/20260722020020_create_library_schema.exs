defmodule Pageless.Repo.Migrations.CreateLibrarySchema do
  use Ecto.Migration

  def change do
    create table(:libraries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :media_type, :string, null: false, default: "book"
      add :store_covers_with_item, :boolean, null: false, default: true
      add :store_metadata_with_item, :boolean, null: false, default: true
      add :auto_scan_on_file_changes, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create table(:library_folders, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :path, :string, null: false

      add :library_id, references(:libraries, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:library_folders, [:library_id])
    create unique_index(:library_folders, [:library_id, :path])

    create table(:authors, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:authors, [:name])

    create table(:series, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:series, [:name])

    create table(:publishers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:publishers, ["lower(name)"], name: :publishers_name_ci_index)

    create table(:books, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :subtitle, :string
      add :description, :text
      add :published_date, :date
      add :isbn, :string
      add :asin, :string
      add :language, :string
      add :cover_path, :string
      add :duration_seconds, :float, null: false, default: 0.0
      add :folder_path, :string, null: false
      add :mtime, :utc_datetime
      add :size, :bigint
      add :scanned_at, :utc_datetime
      add :missing_since, :utc_datetime
      add :source_identity, :string
      add :generated_metadata_hash, :string
      add :generated_cover_hash, :string

      add :library_id, references(:libraries, type: :binary_id, on_delete: :delete_all),
        null: false

      add :publisher_id, references(:publishers, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:books, [:library_id])
    create unique_index(:books, [:library_id, :folder_path])
    create index(:books, [:publisher_id])
    create index(:books, [:library_id, :missing_since])
    create index(:books, [:library_id, :source_identity])

    create table(:books_authors, primary_key: false) do
      add :book_id, references(:books, type: :binary_id, on_delete: :delete_all), null: false
      add :author_id, references(:authors, type: :binary_id, on_delete: :delete_all), null: false
    end

    create unique_index(:books_authors, [:book_id, :author_id])
    create index(:books_authors, [:author_id])

    create table(:book_series, primary_key: false) do
      add :book_id, references(:books, type: :binary_id, on_delete: :delete_all), null: false
      add :series_id, references(:series, type: :binary_id, on_delete: :delete_all), null: false
      add :sequence, :string, null: false
    end

    create unique_index(:book_series, [:book_id, :series_id])
    create index(:book_series, [:series_id])

    create table(:audio_files, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :path, :string, null: false
      add :index, :integer, null: false, default: 0
      add :duration_seconds, :float, null: false, default: 0.0
      add :codec, :string
      add :bitrate, :integer
      add :mime_type, :string
      add :size, :bigint
      add :book_id, references(:books, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:audio_files, [:book_id])
    create unique_index(:audio_files, [:book_id, :index])

    create table(:chapters, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string
      add :start_seconds, :float, null: false
      add :end_seconds, :float, null: false
      add :index, :integer, null: false, default: 0
      add :book_id, references(:books, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:chapters, [:book_id])

    create table(:users_libraries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :library_id, references(:libraries, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users_libraries, [:user_id, :library_id])
    create index(:users_libraries, [:library_id])

    create table(:genres, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:genres, [:name])

    create table(:books_genres, primary_key: false) do
      add :book_id, references(:books, type: :binary_id, on_delete: :delete_all), null: false
      add :genre_id, references(:genres, type: :binary_id, on_delete: :delete_all), null: false
    end

    create unique_index(:books_genres, [:book_id, :genre_id])
    create index(:books_genres, [:genre_id])

    create table(:collections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text

      add :library_id, references(:libraries, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:collections, [:library_id])
    create unique_index(:collections, [:library_id, :name])

    create table(:book_collections, primary_key: false) do
      add :book_id, references(:books, type: :binary_id, on_delete: :delete_all), null: false

      add :collection_id, references(:collections, type: :binary_id, on_delete: :delete_all),
        null: false

      add :position, :integer, null: false, default: 0
    end

    create unique_index(:book_collections, [:collection_id, :book_id])
    create index(:book_collections, [:book_id])

    create table(:playlists, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:playlists, [:user_id])
    create unique_index(:playlists, [:user_id, :name])

    create table(:playlist_books, primary_key: false) do
      add :playlist_id, references(:playlists, type: :binary_id, on_delete: :delete_all),
        null: false

      add :book_id, references(:books, type: :binary_id, on_delete: :delete_all), null: false
      add :position, :integer, null: false, default: 0
    end

    create unique_index(:playlist_books, [:playlist_id, :book_id])
    create index(:playlist_books, [:book_id])

    create table(:narrators, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:narrators, ["lower(name)"], name: :narrators_name_ci_index)

    create table(:book_narrators, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :book_id, references(:books, type: :binary_id, on_delete: :delete_all), null: false

      add :narrator_id, references(:narrators, type: :binary_id, on_delete: :delete_all),
        null: false

      add :position, :integer, null: false
    end

    create unique_index(:book_narrators, [:book_id, :narrator_id])
    create unique_index(:book_narrators, [:book_id, :position])
    create index(:book_narrators, [:narrator_id])
  end
end
