defmodule Pageless.Library.Book do
  use Ecto.Schema
  import Ecto.Changeset

  alias Pageless.Library.{
    AudioFile,
    Author,
    BookCollection,
    BookNarrator,
    BookSeries,
    Chapter,
    Collection,
    Genre,
    Library,
    Playlist,
    PlaylistBook,
    Publisher,
    Series
  }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "books" do
    field :title, :string
    field :subtitle, :string
    field :description, :string
    field :publisher_name, :string, virtual: true
    field :published_date, :date
    field :isbn, :string
    field :asin, :string
    field :language, :string
    field :cover_path, :string
    field :duration_seconds, :float, default: 0.0
    field :folder_path, :string
    field :mtime, :utc_datetime
    field :size, :integer
    field :scanned_at, :utc_datetime
    field :missing_since, :utc_datetime
    field :source_identity, :string
    field :generated_metadata_hash, :string
    field :generated_cover_hash, :string

    belongs_to :library, Library
    belongs_to :publisher, Publisher, on_replace: :nilify

    has_many :audio_files, AudioFile, on_replace: :delete
    has_many :chapters, Chapter, on_replace: :delete

    many_to_many :authors, Author, join_through: "books_authors", on_replace: :delete
    many_to_many :series, Series, join_through: "book_series", on_replace: :delete
    many_to_many :genres, Genre, join_through: "books_genres", on_replace: :delete

    has_many :book_narrators, BookNarrator, preload_order: [asc: :position], on_replace: :delete
    has_many :narrators, through: [:book_narrators, :narrator]

    has_many :book_series, BookSeries, on_replace: :delete

    many_to_many :collections, Collection,
      join_through: "book_collections",
      on_replace: :delete

    has_many :book_collections, BookCollection, on_replace: :delete

    many_to_many :playlists, Playlist,
      join_through: "playlist_books",
      on_replace: :delete

    has_many :playlist_books, PlaylistBook, on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(book, attrs) do
    book
    |> cast(attrs, [
      :title,
      :subtitle,
      :description,
      :published_date,
      :isbn,
      :asin,
      :language,
      :cover_path,
      :duration_seconds,
      :folder_path,
      :mtime,
      :size,
      :scanned_at,
      :missing_since,
      :source_identity,
      :generated_metadata_hash,
      :generated_cover_hash
    ])
    |> validate_required([:title, :folder_path])
    |> unique_constraint([:library_id, :folder_path])
  end

  @doc """
  Changeset for user-editable metadata (the Edit modal's Details tab).
  """
  def details_changeset(book, attrs) do
    book
    |> cast(attrs, [
      :title,
      :subtitle,
      :description,
      :publisher_name,
      :published_date,
      :isbn,
      :asin,
      :language
    ])
    |> validate_required([:title])
  end
end
