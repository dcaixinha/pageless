defmodule PagelessWeb.API.ApiJSON do
  @moduledoc """
  Shared JSON serializers for the mobile API. Kept in one place so the wire
  contract for each entity is defined once and reused across controllers.
  """

  alias Pageless.Accounts
  alias Pageless.Playback

  @doc "Renders a user (safe, public fields only)."
  def user(user) do
    settings = Accounts.get_player_settings(user)

    %{
      id: user.id,
      first_name: user.first_name,
      last_name: user.last_name,
      email: user.email,
      role: user.role,
      ignore_prefixes_when_sorting: settings.ignore_prefixes_when_sorting,
      date_format: settings.date_format,
      time_format: settings.time_format,
      permissions: permissions(user)
    }
  end

  defp permissions(%Pageless.Accounts.User{role: "admin"}) do
    permissions(%Pageless.Accounts.UserPermissions{
      can_download: true,
      can_update: true,
      can_delete: true,
      can_upload: true,
      can_access_all_libraries: true
    })
  end

  defp permissions(%Pageless.Accounts.User{permissions: nil}) do
    permissions(%Pageless.Accounts.UserPermissions{})
  end

  defp permissions(%Pageless.Accounts.User{permissions: permissions}) do
    permissions(permissions)
  end

  defp permissions(permissions) do
    %{
      can_download: permissions.can_download,
      can_update: permissions.can_update,
      can_delete: permissions.can_delete,
      can_upload: permissions.can_upload,
      can_access_all_libraries: permissions.can_access_all_libraries
    }
  end

  @doc "Renders a library."
  def library(lib) do
    %{id: lib.id, name: lib.name}
  end

  @doc "Renders a series with its ordered books (each with a `sequence`)."
  def series_summary(series) do
    %{
      id: series.id,
      name: series.name,
      books: series_books(series)
    }
  end

  @doc "Renders a series with its ordered books (same shape as summary)."
  def series_detail(series), do: series_summary(series)

  defp series_books(%{book_series: book_series}) when is_list(book_series) do
    Enum.map(book_series, fn bs ->
      bs.book |> book_summary() |> Map.put(:sequence, bs.sequence)
    end)
  end

  defp series_books(_series), do: []

  @doc "Renders a collection summary (books as compact summaries, in order)."
  def collection(collection) do
    %{
      id: collection.id,
      name: collection.name,
      description: collection.description,
      library_id: collection.library_id,
      books: collection_books(collection),
      updated_at: iso(collection.updated_at)
    }
  end

  @doc "Renders a collection with its ordered books (same shape as summary)."
  def collection_detail(collection), do: collection(collection)

  defp collection_books(%{book_collections: book_collections}) when is_list(book_collections) do
    Enum.map(book_collections, fn bc -> book_summary(bc.book) end)
  end

  defp collection_books(_collection), do: []

  @doc "Renders a playlist summary (books as compact summaries, in order)."
  def playlist(playlist) do
    %{
      id: playlist.id,
      name: playlist.name,
      description: playlist.description,
      books: playlist_books(playlist),
      updated_at: iso(playlist.updated_at)
    }
  end

  @doc "Renders a playlist with its ordered books (same shape as summary)."
  def playlist_detail(playlist), do: playlist(playlist)

  defp playlist_books(%{playlist_books: playlist_books}) when is_list(playlist_books) do
    Enum.map(playlist_books, fn pb -> book_summary(pb.book) end)
  end

  defp playlist_books(_playlist), do: []

  @doc "Renders a compact book summary for list views."
  def book_summary(book) do
    %{
      id: book.id,
      title: book.title,
      subtitle: book.subtitle,
      authors: authors(book),
      genres: genres(book),
      narrators: narrators(book),
      publisher: publisher(book),
      series: summary_series(book),
      language: book.language,
      duration_seconds: book.duration_seconds,
      size: book.size,
      published_date: book.published_date && Date.to_iso8601(book.published_date),
      published_year: book.published_date && book.published_date.year,
      added_at: iso(book.inserted_at),
      file_modified: iso(book.mtime),
      library_id: book.library_id,
      has_cover: is_binary(book.cover_path),
      updated_at: iso(book.updated_at)
    }
  end

  @doc "Renders a book with full detail: chapters, audio files, and progress."
  def book_detail(book, progress) do
    book_summary(book)
    |> Map.merge(%{
      description: book.description,
      isbn: book.isbn,
      asin: book.asin,
      series: series(book),
      chapters: Enum.map(book.chapters, &chapter/1),
      audio_files: Enum.map(book.audio_files, &audio_file/1),
      progress: progress && progress(progress)
    })
  end

  defp series(%{book_series: book_series}) when is_list(book_series) do
    Enum.map(book_series, fn bs ->
      %{id: bs.series.id, name: bs.series.name, sequence: bs.sequence}
    end)
  end

  defp series(_book), do: []

  defp summary_series(%{series: series}) when is_list(series) do
    Enum.map(series, &%{id: &1.id, name: &1.name})
  end

  defp summary_series(_book), do: []

  defp narrators(%{book_narrators: book_narrators}) when is_list(book_narrators) do
    Enum.map(book_narrators, fn book_narrator ->
      %{id: book_narrator.narrator.id, name: book_narrator.narrator.name}
    end)
  end

  defp narrators(_book), do: []

  defp publisher(%{publisher: %{id: id, name: name}}), do: %{id: id, name: name}
  defp publisher(_book), do: nil

  @doc "Renders a chapter."
  def chapter(ch) do
    %{
      id: ch.id,
      title: ch.title,
      index: ch.index,
      start_seconds: ch.start_seconds,
      end_seconds: ch.end_seconds
    }
  end

  @doc "Renders an audio file (metadata; bytes are fetched via the download endpoint)."
  def audio_file(af) do
    %{
      id: af.id,
      index: af.index,
      mime_type: af.mime_type,
      size: af.size,
      duration_seconds: af.duration_seconds
    }
  end

  @doc "Renders a playback progress record."
  def progress(p) do
    %{
      book_id: p.book_id,
      current_seconds: p.current_seconds,
      duration_seconds: p.duration_seconds,
      finished: Playback.finished?(p),
      finished_at: iso(p.finished_at),
      started_at: iso(p.started_at),
      last_played_at: iso(p.last_played_at),
      deleted: not is_nil(p.deleted_at),
      updated_at: iso(p.updated_at)
    }
  end

  @doc "Renders a bookmark."
  def bookmark(b) do
    %{
      id: b.id,
      book_id: b.book_id,
      position_seconds: b.position_seconds,
      note: b.note,
      deleted: not is_nil(b.deleted_at),
      updated_at: iso(b.updated_at)
    }
  end

  @doc "Renders a synced listening history ack."
  def listening_history_ack do
    %{ok: true}
  end

  defp authors(book) do
    case book.authors do
      %Ecto.Association.NotLoaded{} -> []
      authors -> Enum.map(authors, &%{id: &1.id, name: &1.name})
    end
  end

  defp genres(book) do
    case book.genres do
      %Ecto.Association.NotLoaded{} -> []
      genres -> Enum.map(genres, &%{id: &1.id, name: &1.name})
    end
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
