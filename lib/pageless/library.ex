defmodule Pageless.Library do
  @moduledoc """
  The Library context: libraries, folders, books, audio files, chapters,
  authors and series.
  """

  import Ecto.Query, warn: false

  alias Pageless.Accounts
  alias Pageless.Accounts.Scope
  alias Pageless.Repo

  alias Pageless.Accounts.User
  alias Pageless.Playback.PlaybackProgress

  alias Pageless.Library.{
    Author,
    Book,
    BookCollection,
    BookNarrator,
    BookSeries,
    Chapter,
    Collection,
    Events,
    Genre,
    Library,
    LibraryFolder,
    Narrator,
    Playlist,
    PlaylistBook,
    Publisher,
    RemoteCover,
    Series,
    Sorting
  }

  ## Libraries

  def list_libraries do
    Library
    |> order_by(asc: :name)
    |> preload(:folders)
    |> Repo.all()
  end

  def list_libraries(%Scope{} = scope) do
    Library
    |> maybe_filter_library_access(Accounts.accessible_library_ids(scope))
    |> order_by(asc: :name)
    |> preload(:folders)
    |> Repo.all()
  end

  defp maybe_filter_library_access(query, :all), do: query
  defp maybe_filter_library_access(query, []), do: where(query, [library], false)

  defp maybe_filter_library_access(query, library_ids),
    do: where(query, [library], library.id in ^library_ids)

  def get_library!(id), do: Library |> preload(:folders) |> Repo.get!(id)

  def get_library(id), do: Library |> preload(:folders) |> Repo.get(id)

  def create_library(attrs) do
    %Library{}
    |> Library.changeset(attrs)
    |> Repo.insert()
    |> notify_library_changed(false)
  end

  def update_library(%Library{} = library, attrs) do
    library
    |> Library.changeset(attrs)
    |> Repo.update()
    |> mark_removed_roots_missing_result()
    |> notify_library_changed(true)
  end

  def delete_library(%Library{} = library) do
    result = Repo.delete(library)

    if match?({:ok, _library}, result) and Process.whereis(Pageless.Library.ScanCoordinator) do
      Pageless.Library.ScanCoordinator.library_deleted(library.id)
    end

    result
  end

  def change_library(%Library{} = library, attrs \\ %{}) do
    Library.changeset(library, attrs)
  end

  defp notify_library_changed({:ok, library} = result, scan?) do
    if Application.get_env(:pageless, :start_library_watchers, true) and
         Process.whereis(Pageless.Library.ScanCoordinator) do
      Pageless.Library.ScanCoordinator.library_changed(library.id, scan?)
    end

    result
  end

  defp notify_library_changed(result, _scan?), do: result

  defp mark_removed_roots_missing_result({:ok, library} = result) do
    mark_books_outside_library_roots_missing(library)
    result
  end

  defp mark_removed_roots_missing_result(result), do: result

  def mark_books_outside_library_roots_missing(%Library{} = library) do
    library = Repo.preload(library, :folders, force: true)
    roots = Enum.map(library.folders, &Path.expand(&1.path))
    now = DateTime.utc_now(:second)

    missing_ids =
      Book
      |> where(library_id: ^library.id)
      |> Repo.all()
      |> Enum.reduce([], fn book, ids ->
        path = Path.expand(book.folder_path)
        retained? = Enum.any?(roots, &(path == &1 or String.starts_with?(path, &1 <> "/")))

        if retained? or not is_nil(book.missing_since) do
          ids
        else
          book |> Ecto.Changeset.change(missing_since: now) |> Repo.update!()
          [book.id | ids]
        end
      end)

    if missing_ids != [], do: Events.broadcast_changed(library.id, [], missing_ids)
    missing_ids
  end

  ## Folders

  def list_folders(%Library{} = library) do
    LibraryFolder
    |> where(library_id: ^library.id)
    |> order_by(asc: :path)
    |> Repo.all()
  end

  ## Books

  @doc """
  Lists books in a library with optional search, sort, and facet filters.

  Options:

    * `:library_id` - filter to a library
    * `:search` - case-insensitive match on title/author/narrator
    * `:sort` - title, author, date, size, duration, progress, or random ordering
    * `:sort_direction` - `:asc` or `:desc`; defaults preserve the established sort order
    * `:author_ids` - match any of the authors
    * `:narrator_ids` - match any of the narrators
    * `:publisher_ids` - match any of the publishers
    * `:genre_ids` - match any of the genres
    * `:series_ids` - match any of the series
    * `:collection_ids` - match any of the collections
    * `:playlist_ids` - match any of the scoped user's playlists
    * `:languages` - match any exact language value
    * `:library_ids` - match any of the libraries
    * `:progress` - match any of `:not_started`, `:in_progress`, `:finished`
  """
  def list_books(opts \\ []) do
    Book
    |> active_books()
    |> apply_book_filters(opts, nil, false)
    |> Repo.all()
    |> maybe_shuffle_books(opts[:sort])
  end

  def list_books(%Scope{user: user} = scope, opts) do
    ignore_prefixes? = Accounts.get_player_settings(user).ignore_prefixes_when_sorting

    Book
    |> active_books()
    |> maybe_filter_access(Accounts.accessible_library_ids(scope))
    |> apply_book_filters(opts, user.id, ignore_prefixes?)
    |> Repo.all()
    |> maybe_shuffle_books(opts[:sort])
  end

  defp apply_book_filters(query, opts, user_id, ignore_prefixes?) do
    query
    |> maybe_filter_library(opts[:library_id])
    |> maybe_filter_libraries(opts[:library_ids])
    |> maybe_filter_authors(opts[:author_ids])
    |> maybe_filter_narrators(opts[:narrator_ids])
    |> maybe_filter_publishers(opts[:publisher_ids])
    |> maybe_filter_genres(opts[:genre_ids])
    |> maybe_filter_series(opts[:series_ids])
    |> maybe_filter_collections(opts[:collection_ids])
    |> maybe_filter_playlists(opts[:playlist_ids], user_id)
    |> maybe_filter_languages(opts[:languages])
    |> maybe_filter_progress(opts[:progress], user_id)
    |> maybe_search(opts[:search])
    |> apply_sort(opts[:sort], opts[:sort_direction], user_id, ignore_prefixes?)
    |> preload([:authors, :series, :genres, :publisher, book_narrators: :narrator])
  end

  defp maybe_filter_access(query, :all), do: query
  defp maybe_filter_access(query, []), do: where(query, [b], false)

  defp maybe_filter_access(query, library_ids),
    do: where(query, [b], b.library_id in ^library_ids)

  defp maybe_filter_library(query, nil), do: query
  defp maybe_filter_library(query, library_id), do: where(query, library_id: ^library_id)

  defp maybe_filter_libraries(query, library_ids) when library_ids in [nil, []], do: query

  defp maybe_filter_libraries(query, library_ids),
    do: where(query, [b], b.library_id in ^library_ids)

  defp maybe_filter_authors(query, author_ids) when author_ids in [nil, []], do: query

  defp maybe_filter_authors(query, author_ids) do
    book_ids =
      from ba in "books_authors",
        where: type(field(ba, :author_id), :binary_id) in ^author_ids,
        select: type(field(ba, :book_id), :binary_id)

    where(query, [b], b.id in subquery(book_ids))
  end

  defp maybe_filter_narrators(query, narrator_ids) when narrator_ids in [nil, []], do: query

  defp maybe_filter_narrators(query, narrator_ids) do
    book_ids =
      from bn in BookNarrator,
        where: bn.narrator_id in ^narrator_ids,
        select: bn.book_id

    where(query, [b], b.id in subquery(book_ids))
  end

  defp maybe_filter_publishers(query, publisher_ids) when publisher_ids in [nil, []], do: query

  defp maybe_filter_publishers(query, publisher_ids),
    do: where(query, [b], b.publisher_id in ^publisher_ids)

  defp maybe_filter_genres(query, genre_ids) when genre_ids in [nil, []], do: query

  defp maybe_filter_genres(query, genre_ids) do
    book_ids =
      from bg in "books_genres",
        where: type(field(bg, :genre_id), :binary_id) in ^genre_ids,
        select: type(field(bg, :book_id), :binary_id)

    where(query, [b], b.id in subquery(book_ids))
  end

  defp maybe_filter_series(query, series_ids) when series_ids in [nil, []], do: query

  defp maybe_filter_series(query, series_ids) do
    book_ids =
      from bs in "book_series",
        where: type(field(bs, :series_id), :binary_id) in ^series_ids,
        select: type(field(bs, :book_id), :binary_id)

    where(query, [b], b.id in subquery(book_ids))
  end

  defp maybe_filter_collections(query, collection_ids) when collection_ids in [nil, []], do: query

  defp maybe_filter_collections(query, collection_ids) do
    book_ids =
      from bc in BookCollection,
        where: bc.collection_id in ^collection_ids,
        select: bc.book_id

    where(query, [b], b.id in subquery(book_ids))
  end

  defp maybe_filter_playlists(query, playlist_ids, _user_id) when playlist_ids in [nil, []],
    do: query

  defp maybe_filter_playlists(query, _playlist_ids, nil), do: query

  defp maybe_filter_playlists(query, playlist_ids, user_id) do
    book_ids =
      from pb in PlaylistBook,
        join: p in Playlist,
        on: p.id == pb.playlist_id,
        where: p.user_id == ^user_id and p.id in ^playlist_ids,
        select: pb.book_id

    where(query, [b], b.id in subquery(book_ids))
  end

  defp maybe_filter_languages(query, languages) when languages in [nil, []], do: query
  defp maybe_filter_languages(query, languages), do: where(query, [b], b.language in ^languages)

  defp maybe_filter_progress(query, progress, _user_id) when progress in [nil, []], do: query

  defp maybe_filter_progress(query, progress, user_id) when not is_nil(user_id) do
    states = MapSet.new(progress)

    if MapSet.equal?(states, MapSet.new([:not_started, :in_progress, :finished])) do
      query
    else
      progress_filter =
        false
        |> include_progress_state(
          states,
          :not_started,
          dynamic([filter_progress: p], is_nil(p.id))
        )
        |> include_progress_state(
          states,
          :in_progress,
          dynamic([filter_progress: p], not is_nil(p.id) and is_nil(p.finished_at))
        )
        |> include_progress_state(
          states,
          :finished,
          dynamic([filter_progress: p], not is_nil(p.finished_at))
        )

      query
      |> join(:left, [b], p in PlaybackProgress,
        as: :filter_progress,
        on: p.book_id == b.id and p.user_id == ^user_id and is_nil(p.deleted_at)
      )
      |> where(^progress_filter)
    end
  end

  defp maybe_filter_progress(query, _progress, nil), do: query

  defp include_progress_state(filter, states, state, expression) do
    if MapSet.member?(states, state), do: dynamic(^filter or ^expression), else: filter
  end

  defp maybe_search(query, term) when term in [nil, ""], do: query

  defp maybe_search(query, term) do
    like = "%#{String.replace(term, "%", "\\%")}%"

    author_book_ids =
      from ba in "books_authors",
        join: a in Author,
        on: a.id == type(field(ba, :author_id), :binary_id),
        where: ilike(a.name, ^like),
        select: type(field(ba, :book_id), :binary_id)

    narrator_book_ids =
      from bn in BookNarrator,
        join: n in Narrator,
        on: n.id == bn.narrator_id,
        where: ilike(n.name, ^like),
        select: bn.book_id

    publisher_book_ids =
      from b in Book,
        join: p in Publisher,
        on: p.id == b.publisher_id,
        where: ilike(p.name, ^like),
        select: b.id

    from b in query,
      where:
        ilike(b.title, ^like) or ilike(coalesce(b.subtitle, ""), ^like) or
          b.id in subquery(author_book_ids) or b.id in subquery(narrator_book_ids) or
          b.id in subquery(publisher_book_ids)
  end

  defp apply_sort(query, :title, :desc, _user_id, ignore_prefixes?),
    do: order_by_title(query, :desc, ignore_prefixes?)

  defp apply_sort(query, :title, _direction, _user_id, ignore_prefixes?),
    do: order_by_title(query, :asc, ignore_prefixes?)

  defp apply_sort(query, :author_first, direction, _user_id, ignore_prefixes?) do
    order_by_author_first(query, direction, ignore_prefixes?)
  end

  defp apply_sort(query, :author_last, direction, _user_id, ignore_prefixes?) do
    order_by_author_last(query, direction, ignore_prefixes?)
  end

  defp apply_sort(query, :published, direction, _user_id, ignore_prefixes?),
    do: order_by_field(query, :published_date, direction, ignore_prefixes?)

  defp apply_sort(query, :added, direction, _user_id, ignore_prefixes?),
    do: order_by_field(query, :inserted_at, direction, ignore_prefixes?)

  defp apply_sort(query, :size, direction, _user_id, ignore_prefixes?),
    do: order_by_field(query, :size, direction, ignore_prefixes?)

  defp apply_sort(query, :duration, direction, _user_id, ignore_prefixes?),
    do: order_by_field(query, :duration_seconds, direction, ignore_prefixes?)

  defp apply_sort(query, :modified, direction, _user_id, ignore_prefixes?),
    do: order_by_field(query, :mtime, direction, ignore_prefixes?)

  defp apply_sort(query, sort, direction, user_id, ignore_prefixes?)
       when sort in [:progress_updated, :progress_started, :progress_finished] and
              not is_nil(user_id) do
    field =
      case sort do
        :progress_updated -> :updated_at
        :progress_started -> :started_at
        :progress_finished -> :finished_at
      end

    query
    |> join(:left, [b], p in PlaybackProgress,
      as: :sort_progress,
      on: p.book_id == b.id and p.user_id == ^user_id and is_nil(p.deleted_at)
    )
    |> order_by_progress(field, direction, ignore_prefixes?)
  end

  defp apply_sort(query, :random, _direction, _user_id, _ignore_prefixes?), do: query

  defp apply_sort(query, _sort, direction, user_id, ignore_prefixes?),
    do: apply_sort(query, :title, direction, user_id, ignore_prefixes?)

  defp order_by_author_first(query, :desc, ignore_prefixes?) do
    query
    |> order_by([b],
      desc_nulls_last:
        fragment(
          "(SELECT MIN(lower(a.name)) FROM authors a JOIN books_authors ba ON ba.author_id = a.id WHERE ba.book_id = ?)",
          b.id
        )
    )
    |> order_by_title(:asc, ignore_prefixes?)
  end

  defp order_by_author_first(query, _direction, ignore_prefixes?) do
    query
    |> order_by([b],
      asc_nulls_last:
        fragment(
          "(SELECT MIN(lower(a.name)) FROM authors a JOIN books_authors ba ON ba.author_id = a.id WHERE ba.book_id = ?)",
          b.id
        )
    )
    |> order_by_title(:asc, ignore_prefixes?)
  end

  defp order_by_author_last(query, :desc, ignore_prefixes?) do
    query
    |> order_by([b],
      desc_nulls_last:
        fragment(
          "(SELECT MIN(lower(CASE WHEN trim(a.name) ~* ' ((da|de|do|dos|das|van|von|le|la|del|der|den) )+[^ ]+$' THEN regexp_replace(trim(a.name), '^(.*) (((da|de|do|dos|das|van|von|le|la|del|der|den) )+[^ ]+)$', '\\2, \\1', 'i') ELSE regexp_replace(trim(a.name), '^(.*) ([^ ]+)$', '\\2, \\1') END)) FROM authors a JOIN books_authors ba ON ba.author_id = a.id WHERE ba.book_id = ?)",
          b.id
        )
    )
    |> order_by_title(:asc, ignore_prefixes?)
  end

  defp order_by_author_last(query, _direction, ignore_prefixes?) do
    query
    |> order_by([b],
      asc_nulls_last:
        fragment(
          "(SELECT MIN(lower(CASE WHEN trim(a.name) ~* ' ((da|de|do|dos|das|van|von|le|la|del|der|den) )+[^ ]+$' THEN regexp_replace(trim(a.name), '^(.*) (((da|de|do|dos|das|van|von|le|la|del|der|den) )+[^ ]+)$', '\\2, \\1', 'i') ELSE regexp_replace(trim(a.name), '^(.*) ([^ ]+)$', '\\2, \\1') END)) FROM authors a JOIN books_authors ba ON ba.author_id = a.id WHERE ba.book_id = ?)",
          b.id
        )
    )
    |> order_by_title(:asc, ignore_prefixes?)
  end

  defp order_by_field(query, field, :asc, ignore_prefixes?) do
    query
    |> order_by([b], asc_nulls_last: field(b, ^field))
    |> order_by_title(:asc, ignore_prefixes?)
  end

  defp order_by_field(query, field, _direction, ignore_prefixes?) do
    query
    |> order_by([b], desc_nulls_last: field(b, ^field))
    |> order_by_title(:asc, ignore_prefixes?)
  end

  defp order_by_progress(query, field, :asc, ignore_prefixes?) do
    query
    |> order_by([_b, sort_progress: p], asc_nulls_last: field(p, ^field))
    |> order_by_title(:asc, ignore_prefixes?)
  end

  defp order_by_progress(query, field, _direction, ignore_prefixes?) do
    query
    |> order_by([_b, sort_progress: p], desc_nulls_last: field(p, ^field))
    |> order_by_title(:asc, ignore_prefixes?)
  end

  defp order_by_title(query, direction, ignore_prefixes?) do
    key =
      if ignore_prefixes? do
        pattern = Sorting.sql_ignored_prefix()

        dynamic(
          [b],
          fragment("lower(regexp_replace(btrim(?), ?, '', 'i'))", b.title, ^pattern)
        )
      else
        dynamic([b], fragment("lower(btrim(?))", b.title))
      end

    order_by(
      query,
      ^[
        {direction, key},
        {:asc, dynamic([b], fragment("lower(btrim(?))", b.title))}
      ]
    )
  end

  defp maybe_shuffle_books(books, :random), do: Enum.shuffle(books)
  defp maybe_shuffle_books(books, _sort), do: books

  @doc """
  Returns filter values represented by books visible to the scoped user.
  """
  def book_filter_options(%Scope{} = scope) do
    accessible_books =
      Book
      |> active_books()
      |> maybe_filter_access(Accounts.accessible_library_ids(scope))
      |> select([b], b.id)

    %{
      authors: filter_entities(Author, :books, accessible_books),
      narrators: filter_narrators(accessible_books),
      publishers: filter_entities(Publisher, :books, accessible_books),
      genres: filter_entities(Genre, :books, accessible_books),
      series: filter_entities(Series, :books, accessible_books),
      collections: filter_collections(accessible_books),
      playlists: filter_playlists(accessible_books, scope.user.id),
      languages: filter_languages(accessible_books),
      libraries: filter_libraries(accessible_books)
    }
  end

  defp filter_entities(schema, association, accessible_books) do
    schema
    |> join(:inner, [entity], b in assoc(entity, ^association))
    |> where([_entity, b], b.id in subquery(accessible_books))
    |> group_by([entity], [entity.id, entity.name])
    |> order_by([entity], asc: entity.name)
    |> select([entity, b], %{id: entity.id, name: entity.name, book_count: count(b.id, :distinct)})
    |> Repo.all()
  end

  defp filter_libraries(accessible_books) do
    Library
    |> join(:inner, [library], b in assoc(library, :books))
    |> where([_library, b], b.id in subquery(accessible_books))
    |> group_by([library], [library.id, library.name])
    |> order_by([library], asc: library.name)
    |> select([library, b], %{
      id: library.id,
      name: library.name,
      book_count: count(b.id, :distinct)
    })
    |> Repo.all()
  end

  defp filter_narrators(accessible_books) do
    Narrator
    |> join(:inner, [n], bn in BookNarrator, on: bn.narrator_id == n.id)
    |> where([_n, bn], bn.book_id in subquery(accessible_books))
    |> group_by([n], [n.id, n.name])
    |> order_by([n], asc: n.name)
    |> select([n, bn], %{id: n.id, name: n.name, book_count: count(bn.book_id, :distinct)})
    |> Repo.all()
  end

  defp filter_collections(accessible_books) do
    Collection
    |> join(:inner, [c], bc in BookCollection, on: bc.collection_id == c.id)
    |> where([_c, bc], bc.book_id in subquery(accessible_books))
    |> group_by([c], [c.id, c.name])
    |> order_by([c], asc: c.name)
    |> select([c, bc], %{id: c.id, name: c.name, book_count: count(bc.book_id, :distinct)})
    |> Repo.all()
  end

  defp filter_playlists(accessible_books, user_id) do
    Playlist
    |> join(:inner, [p], pb in PlaylistBook, on: pb.playlist_id == p.id)
    |> where([p, pb], p.user_id == ^user_id and pb.book_id in subquery(accessible_books))
    |> group_by([p], [p.id, p.name])
    |> order_by([p], asc: p.name)
    |> select([p, pb], %{id: p.id, name: p.name, book_count: count(pb.book_id, :distinct)})
    |> Repo.all()
  end

  defp filter_languages(accessible_books) do
    Book
    |> where([b], b.id in subquery(accessible_books))
    |> where([b], not is_nil(b.language) and fragment("btrim(?) <> ''", b.language))
    |> group_by([b], b.language)
    |> order_by([b], asc: b.language)
    |> select([b], %{id: b.language, name: b.language, book_count: count(b.id, :distinct)})
    |> Repo.all()
  end

  @doc """
  Returns the most recently added books, preloaded with authors.
  """
  def recently_added(limit \\ 12) do
    Book
    |> active_books()
    |> recently_added_query(limit)
    |> Repo.all()
  end

  def recently_added(%Scope{} = scope, limit) do
    Book
    |> active_books()
    |> maybe_filter_access(Accounts.accessible_library_ids(scope))
    |> recently_added_query(limit)
    |> Repo.all()
  end

  defp recently_added_query(query, limit) do
    query
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> preload([:authors, :series, :genres, :publisher, book_narrators: :narrator])
  end

  def get_book!(id) do
    book_query()
    |> Repo.get!(id)
  end

  def get_book!(%Scope{} = scope, id) do
    case get_book(scope, id) do
      nil -> raise Ecto.NoResultsError, queryable: Book
      book -> book
    end
  end

  def get_book(id) do
    book_query()
    |> Repo.get(id)
  end

  def get_book(%Scope{} = scope, id) do
    book_query()
    |> maybe_filter_access(Accounts.accessible_library_ids(scope))
    |> Repo.get(id)
  end

  defp book_query do
    Book
    |> active_books()
    |> preload([
      :authors,
      :series,
      :genres,
      :library,
      :publisher,
      book_narrators: :narrator,
      book_series: :series,
      book_collections: :collection,
      audio_files: ^from(a in Pageless.Library.AudioFile, order_by: a.index),
      chapters: ^from(c in Chapter, order_by: c.index)
    ])
  end

  @doc """
  Finds a book within a library by its folder path.
  """
  def get_book_by_folder(library_id, folder_path) do
    Repo.get_by(Book, library_id: library_id, folder_path: folder_path)
  end

  def count_books(library_id) do
    Book |> active_books() |> where(library_id: ^library_id) |> Repo.aggregate(:count)
  end

  defp active_books(query), do: where(query, [b], is_nil(b.missing_since))

  def library_stats(scope \\ nil) do
    library_ids = accessible_library_ids_for_stats(scope)
    books = stats_book_query(library_ids)

    %{
      total_items: Repo.aggregate(books, :count),
      total_hours: total_duration_seconds(books) / 3600,
      total_authors: total_authors(library_ids),
      total_size_bytes: total_audio_size_bytes(library_ids),
      audio_tracks: audio_tracks_count(library_ids),
      top_genres: top_genres(5, library_ids),
      top_authors: top_authors(10, library_ids),
      longest_items: longest_items(10, books),
      largest_items: largest_items(10, books)
    }
  end

  def server_year_review(year \\ Date.utc_today().year) do
    {start_dt, end_dt} = year_bounds(year)

    %{
      year: year,
      books_added: count_books_added(start_dt, end_dt),
      authors_added: count_authors_added(start_dt, end_dt),
      sessions_count: count_sessions_in_year(start_dt, end_dt),
      size_added_bytes: size_added_bytes(start_dt, end_dt),
      duration_added_seconds: duration_added_seconds(start_dt, end_dt),
      cover_books: recent_additions(start_dt, end_dt, 16),
      additions: recent_additions(start_dt, end_dt, 5)
    }
  end

  defp count_books_added(start_dt, end_dt) do
    Book
    |> active_books()
    |> where([b], b.inserted_at >= ^start_dt and b.inserted_at < ^end_dt)
    |> Repo.aggregate(:count)
  end

  defp count_authors_added(start_dt, end_dt) do
    Author
    |> where([a], a.inserted_at >= ^start_dt and a.inserted_at < ^end_dt)
    |> Repo.aggregate(:count)
  end

  defp count_sessions_in_year(start_dt, end_dt) do
    Pageless.Playback.ListeningSession
    |> where([s], s.started_at >= ^start_dt and s.started_at < ^end_dt)
    |> Repo.aggregate(:count)
  end

  defp size_added_bytes(start_dt, end_dt) do
    Book
    |> active_books()
    |> join(:left, [b], a in assoc(b, :audio_files))
    |> where([b], b.inserted_at >= ^start_dt and b.inserted_at < ^end_dt)
    |> select([b, a], coalesce(sum(a.size), 0))
    |> Repo.one()
  end

  defp duration_added_seconds(start_dt, end_dt) do
    Book
    |> active_books()
    |> where([b], b.inserted_at >= ^start_dt and b.inserted_at < ^end_dt)
    |> select([b], coalesce(sum(b.duration_seconds), 0.0))
    |> Repo.one()
  end

  defp recent_additions(start_dt, end_dt, limit) do
    Book
    |> active_books()
    |> where([b], b.inserted_at >= ^start_dt and b.inserted_at < ^end_dt)
    |> order_by([b], desc: b.inserted_at)
    |> limit(^limit)
    |> preload(:authors)
    |> Repo.all()
  end

  defp year_bounds(year) do
    start_dt = DateTime.new!(Date.new!(year, 1, 1), ~T[00:00:00], "Etc/UTC")
    end_dt = DateTime.new!(Date.new!(year + 1, 1, 1), ~T[00:00:00], "Etc/UTC")
    {start_dt, end_dt}
  end

  defp accessible_library_ids_for_stats(%Scope{} = scope),
    do: Accounts.accessible_library_ids(scope)

  defp accessible_library_ids_for_stats(_), do: :all

  defp stats_book_query(:all), do: active_books(Book)
  defp stats_book_query([]), do: from(b in Book, where: false)

  defp stats_book_query(library_ids),
    do: from(b in Book, where: b.library_id in ^library_ids and is_nil(b.missing_since))

  defp total_duration_seconds(query) do
    Repo.one(from b in query, select: coalesce(sum(b.duration_seconds), 0.0)) || 0.0
  end

  defp total_authors(library_ids) do
    query =
      Author
      |> join(:inner, [a], ba in "books_authors", on: ba.author_id == a.id)
      |> join(:inner, [a, ba], b in Book, on: b.id == ba.book_id)
      |> filter_joined_book_library(library_ids)

    Repo.one(from [a, _ba, _b] in query, select: count(a.id, :distinct)) || 0
  end

  defp total_audio_size_bytes(library_ids) do
    query =
      Pageless.Library.AudioFile
      |> join(:inner, [a], b in assoc(a, :book))
      |> filter_audio_book_library(library_ids)

    query
    |> select([a], coalesce(sum(a.size), 0))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp audio_tracks_count(library_ids) do
    Pageless.Library.AudioFile
    |> join(:inner, [a], b in assoc(a, :book))
    |> filter_audio_book_library(library_ids)
    |> Repo.aggregate(:count)
  end

  defp top_authors(limit, library_ids) do
    Author
    |> join(:inner, [a], ba in "books_authors", on: ba.author_id == a.id)
    |> join(:inner, [a, ba], b in Book, on: b.id == ba.book_id)
    |> filter_joined_book_library(library_ids)
    |> group_by([a], [a.id, a.name])
    |> order_by([a, ba], desc: count(ba.book_id), asc: a.name)
    |> limit(^limit)
    |> select([a, ba], %{name: a.name, count: count(ba.book_id)})
    |> Repo.all()
  end

  defp top_genres(limit, library_ids) do
    Genre
    |> join(:inner, [g], bg in "books_genres", on: bg.genre_id == g.id)
    |> join(:inner, [g, bg], b in Book, on: b.id == bg.book_id)
    |> filter_joined_book_library(library_ids)
    |> group_by([g], [g.id, g.name])
    |> order_by([g, bg], desc: count(bg.book_id), asc: g.name)
    |> limit(^limit)
    |> select([g, bg], %{name: g.name, count: count(bg.book_id)})
    |> Repo.all()
  end

  defp longest_items(limit, query) do
    query
    |> order_by(desc: :duration_seconds)
    |> limit(^limit)
    |> select([b], %{id: b.id, title: b.title, value: b.duration_seconds})
    |> Repo.all()
  end

  defp largest_items(limit, query) do
    query
    |> join(:left, [b], a in assoc(b, :audio_files))
    |> group_by([b], [b.id, b.title, b.size])
    |> order_by([b, a], desc: coalesce(sum(a.size), b.size))
    |> limit(^limit)
    |> select([b, a], %{id: b.id, title: b.title, value: coalesce(sum(a.size), b.size)})
    |> Repo.all()
  end

  defp filter_joined_book_library(query, :all),
    do: where(query, [_a, _join, b], is_nil(b.missing_since))

  defp filter_joined_book_library(query, []), do: where(query, [_a, _join, _b], false)

  defp filter_joined_book_library(query, library_ids) do
    where(query, [_a, _join, b], b.library_id in ^library_ids and is_nil(b.missing_since))
  end

  defp filter_audio_book_library(query, :all), do: where(query, [_a, b], is_nil(b.missing_since))
  defp filter_audio_book_library(query, []), do: where(query, [_a, _b], false)

  defp filter_audio_book_library(query, library_ids) do
    where(query, [_a, b], b.library_id in ^library_ids and is_nil(b.missing_since))
  end

  def delete_book(%Book{} = book), do: Repo.delete(book)

  @doc """
  Returns a changeset for the book's editable details.
  """
  def change_book(%Book{} = book, attrs \\ %{}) do
    attrs =
      if Map.has_key?(attrs, "publisher_name") or Map.has_key?(attrs, :publisher_name) do
        attrs
      else
        Map.put(attrs, "publisher_name", book.publisher && book.publisher.name)
      end

    Book.details_changeset(book, attrs)
  end

  @doc """
  Updates a book's editable details and normalized metadata associations.
  """
  def update_book(%Book{} = book, attrs) do
    {authors_string, attrs} = Map.pop(attrs, "authors")
    {narrator_names, attrs} = Map.pop(attrs, "narrators")
    {publisher_name, attrs} = Map.pop(attrs, "publisher")
    publisher_form_name = Map.get(attrs, "publisher_name")
    publisher_name = publisher_form_name || publisher_name
    {genres_string, attrs} = Map.pop(attrs, "genres")
    {series_string, attrs} = Map.pop(attrs, "series")
    {collections_string, attrs} = Map.pop(attrs, "collections")

    book = Repo.preload(book, [:authors, :series, :genres, :publisher, book_narrators: :narrator])

    changeset = Book.details_changeset(book, attrs)

    changeset =
      if is_binary(publisher_name) do
        case String.trim(publisher_name) do
          "" ->
            changeset
            |> Ecto.Changeset.put_assoc(:publisher, nil)
            |> Ecto.Changeset.put_change(:publisher_id, nil)

          name ->
            Ecto.Changeset.put_assoc(changeset, :publisher, upsert_publisher(name))
        end
      else
        changeset
      end

    changeset =
      if is_binary(authors_string) do
        Ecto.Changeset.put_assoc(changeset, :authors, parse_authors(authors_string))
      else
        changeset
      end

    changeset =
      if is_binary(genres_string) do
        Ecto.Changeset.put_assoc(changeset, :genres, parse_genres(genres_string))
      else
        changeset
      end

    Repo.transaction(fn ->
      case Repo.update(changeset) do
        {:ok, updated} ->
          if is_list(narrator_names), do: replace_book_narrators(updated, narrator_names)
          if is_binary(series_string), do: replace_book_series_from_string(updated, series_string)

          if is_binary(collections_string),
            do: replace_book_collections(updated, collections_string)

          get_book!(updated.id)

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> sync_metadata_after_success()
  end

  # Replaces a book's series membership from a comma-separated string where each
  # entry may carry a sequence like "Name #3".
  defp replace_book_series_from_string(book, string) do
    replace_book_series(book, parse_series(string))
  end

  # Replaces a book's collection membership from a comma-separated list of
  # collection names (scoped to the book's library).
  defp replace_book_collections(book, string) do
    names = parse_name_list(string)

    Repo.delete_all(from bc in BookCollection, where: bc.book_id == ^book.id)

    names
    |> Enum.map(&upsert_collection(book.library_id, &1))
    |> Enum.each(fn collection ->
      Repo.insert!(
        %BookCollection{collection_id: collection.id, book_id: book.id},
        on_conflict: :nothing,
        conflict_target: [:collection_id, :book_id]
      )
    end)
  end

  @doc """
  Replaces a book's chapters with the given list.

  Each entry is a map with `:title` and `:start_seconds`. Chapters are sorted
  by start time; `end_seconds` is derived from the next chapter's start (or the
  book duration for the final chapter), and `index` is assigned in order.
  """
  def replace_chapters(%Book{} = book, entries) when is_list(entries) do
    duration = book.duration_seconds || 0.0

    sorted =
      entries
      |> Enum.map(fn e ->
        %{title: normalize_title(e[:title]), start: e[:start_seconds] * 1.0}
      end)
      |> Enum.filter(&(&1.start >= 0.0))
      |> Enum.sort_by(& &1.start)

    ends = compute_ends(sorted, duration)

    rows =
      sorted
      |> Enum.zip(ends)
      |> Enum.with_index()
      |> Enum.map(fn {{ch, end_seconds}, index} ->
        %{title: ch.title, start_seconds: ch.start, end_seconds: end_seconds, index: index}
      end)

    Repo.transaction(fn ->
      Repo.delete_all(from c in Chapter, where: c.book_id == ^book.id)

      Enum.each(rows, fn attrs ->
        %Chapter{book_id: book.id}
        |> Chapter.changeset(attrs)
        |> Repo.insert!()
      end)

      get_book!(book.id)
    end)
    |> sync_metadata_after_success()
  end

  defp normalize_title(nil), do: nil

  defp normalize_title(title) do
    case String.trim(title) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # For each chapter, its end is the next chapter's start, or the book duration
  # for the last one (never less than its own start).
  defp compute_ends([], _duration), do: []

  defp compute_ends(sorted, duration) do
    starts = Enum.map(sorted, & &1.start)
    next_starts = tl(starts) ++ [duration]

    Enum.zip(sorted, next_starts)
    |> Enum.map(fn {ch, next_start} -> max(next_start, ch.start) end)
  end

  @doc """
  Sets a book's cover from an uploaded file on disk (already validated),
  storing it in the media dir and updating `cover_path`.
  """
  def set_cover_from_file(%Book{} = book, src_path) do
    with {:ok, dest} <- Pageless.Library.ItemStorage.copy_cover(book, src_path) do
      persist_cover(book, dest)
    end
  end

  @doc """
  Sets a book's cover by downloading an image from a URL.
  """
  def set_cover_from_url(%Book{} = book, url) when is_binary(url) do
    with {:ok, %{body: body, extension: extension}} <- RemoteCover.fetch(url),
         {:ok, dest} <- Pageless.Library.ItemStorage.store_cover(book, body, extension) do
      persist_cover(book, dest)
    end
  end

  defp persist_cover(book, dest) do
    book
    |> Ecto.Changeset.change(cover_path: dest, generated_cover_hash: nil)
    # Touch updated_at so cover URLs bust the browser cache.
    |> Ecto.Changeset.force_change(:updated_at, DateTime.utc_now(:second))
    |> Repo.update()
  end

  defp sync_metadata_after_success({:ok, %Book{} = book} = result) do
    Pageless.Library.ItemStorage.sync_metadata(book)
    result
  end

  defp sync_metadata_after_success(result), do: result

  defp parse_authors(string) do
    string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.map(&upsert_author/1)
  end

  defp parse_genres(string) do
    string
    |> String.split([",", ";", "/", ":"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.map(&upsert_genre/1)
  end

  # Parses "Series A #1, Series B" into [%{name: "Series A", sequence: "1"}, ...]
  defp parse_series(string) do
    string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn entry ->
      case String.split(entry, " #", parts: 2) do
        [name, sequence] -> %{name: String.trim(name), sequence: String.trim(sequence)}
        [name] -> %{name: String.trim(name), sequence: nil}
      end
    end)
    |> Enum.reject(&(&1.name == ""))
    |> Enum.uniq_by(& &1.name)
  end

  # Parses a plain comma-separated list of names.
  defp parse_name_list(string) do
    string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  ## Authors / Series upserts

  @doc """
  Finds or creates an author by name.
  """
  def upsert_author(name) when is_binary(name) do
    name = String.trim(name)

    Repo.insert!(
      %Author{name: name},
      on_conflict: [set: [name: name]],
      conflict_target: :name,
      returning: true
    )
  end

  @doc "Finds or creates a narrator by exact name."
  def upsert_narrator(name) when is_binary(name) do
    name = String.trim(name)
    normalized = String.downcase(name)

    %Narrator{}
    |> Narrator.changeset(%{name: name})
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: {:unsafe_fragment, "(lower(name))"}
    )

    Repo.one!(from n in Narrator, where: fragment("lower(?)", n.name) == ^normalized)
  end

  @doc "Finds or creates a publisher case-insensitively."
  def upsert_publisher(name) when is_binary(name) do
    name = String.trim(name)
    normalized = String.downcase(name)

    %Publisher{}
    |> Publisher.changeset(%{name: name})
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: {:unsafe_fragment, "(lower(name))"}
    )

    Repo.one!(from p in Publisher, where: fragment("lower(?)", p.name) == ^normalized)
  end

  def list_publisher_names(%Scope{} = scope) do
    scope
    |> book_filter_options()
    |> Map.fetch!(:publishers)
    |> Enum.map(& &1.name)
  end

  @doc "Replaces a book's narrators in source/display order."
  def replace_book_narrators(%Book{} = book, names) when is_list(names) do
    names =
      names
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq_by(&String.downcase/1)

    Repo.transaction(fn ->
      Repo.delete_all(from bn in BookNarrator, where: bn.book_id == ^book.id)

      names
      |> Enum.with_index()
      |> Enum.each(fn {name, position} ->
        narrator = upsert_narrator(name)

        %BookNarrator{}
        |> BookNarrator.changeset(%{
          book_id: book.id,
          narrator_id: narrator.id,
          position: position
        })
        |> Repo.insert!()
      end)

      :ok
    end)
  end

  @doc "Returns all narrator names ordered for autocomplete."
  def list_narrator_names do
    Narrator |> order_by(asc: :name) |> select([n], n.name) |> Repo.all()
  end

  def list_narrator_names(%Scope{} = scope) do
    scope
    |> book_filter_options()
    |> Map.fetch!(:narrators)
    |> Enum.map(& &1.name)
  end

  def upsert_genre(name) when is_binary(name) do
    name = String.trim(name)

    %Genre{}
    |> Genre.changeset(%{name: name})
    |> Repo.insert(on_conflict: :nothing, conflict_target: :name)

    Repo.get_by!(Genre, name: name)
  end

  @doc """
  Finds or creates a series by name.
  """
  def upsert_series(name) when is_binary(name) do
    name = String.trim(name)

    Repo.insert!(
      %Series{name: name},
      on_conflict: [set: [name: name]],
      conflict_target: :name,
      returning: true
    )
  end

  @doc """
  Associates `book` with the given series entries, preserving the per-book
  `sequence` on the join row.

  `entries` is a list of `%{name: String.t(), sequence: String.t()}`. A book in a
  series must have a sequence number, so entries with a blank sequence are
  ignored. Existing associations for a series are updated (sequence replaced);
  series not present in `entries` are left untouched (additive, like the
  importer's other relations).
  """
  def set_book_series(%Book{} = book, entries) when is_list(entries) do
    entries
    |> Enum.filter(&valid_series_sequence?(&1[:sequence]))
    |> Enum.each(fn entry ->
      series = upsert_series(entry.name)

      Repo.insert!(
        %BookSeries{book_id: book.id, series_id: series.id, sequence: entry.sequence},
        on_conflict: {:replace, [:sequence]},
        conflict_target: [:book_id, :series_id]
      )
    end)

    book
  end

  defp valid_series_sequence?(sequence),
    do: is_binary(sequence) and String.trim(sequence) != ""

  @doc """
  Replaces a book's entire series membership with `entries` (a list of
  `%{name, sequence}`). Numberless entries are dropped by `set_book_series/2`.
  """
  def replace_book_series(%Book{} = book, entries) when is_list(entries) do
    Repo.delete_all(from bs in BookSeries, where: bs.book_id == ^book.id)
    set_book_series(book, entries)
  end

  @doc """
  Adds `book_id` to the series `series_id` (accessible to `scope`) with the
  given `sequence`. The sequence is required; the book must belong to a library
  accessible to the scope. Upserts the sequence if the book is already in the
  series.
  """
  def add_book_to_series(%Scope{} = scope, series_id, book_id, sequence) do
    series = if get_series(scope, series_id), do: Repo.get(Series, series_id)
    book = Repo.get(Book, book_id)
    accessible_ids = Accounts.accessible_library_ids(scope)

    cond do
      not valid_series_sequence?(sequence) ->
        {:error, :missing_sequence}

      is_nil(series) or is_nil(book) ->
        {:error, :not_found}

      not book_in_accessible_library?(book, accessible_ids) ->
        {:error, :not_found}

      true ->
        Repo.insert!(
          %BookSeries{book_id: book.id, series_id: series.id, sequence: String.trim(sequence)},
          on_conflict: {:replace, [:sequence]},
          conflict_target: [:book_id, :series_id]
        )

        {:ok, series}
    end
  end

  @doc "Removes `book_id` from the series `series_id` (accessible to `scope`)."
  def remove_book_from_series(%Scope{} = scope, series_id, book_id) do
    if get_series(scope, series_id) do
      Repo.delete_all(
        from bs in BookSeries,
          where: bs.series_id == ^series_id and bs.book_id == ^book_id
      )

      {:ok, series_id}
    else
      {:error, :not_found}
    end
  end

  defp book_in_accessible_library?(_book, :all), do: true
  defp book_in_accessible_library?(book, ids) when is_list(ids), do: book.library_id in ids

  @doc """
  Lists series that contain at least one book in a library accessible to
  `scope`, ordered by name, with their books preloaded (ordered by sequence).
  """
  def list_series(%Scope{} = scope) do
    library_ids = Accounts.accessible_library_ids(scope)

    Series
    |> join(:inner, [s], bs in BookSeries, on: bs.series_id == s.id)
    |> join(:inner, [s, bs], b in Book, on: b.id == bs.book_id)
    |> where([_s, _bs, b], is_nil(b.missing_since))
    |> maybe_filter_series_access(library_ids)
    |> distinct(true)
    |> order_by([s], asc: s.name)
    |> preload(^series_books_preload())
    |> Repo.all()
  end

  @doc """
  Fetches a single series accessible to `scope`, with its books ordered by
  sequence. Returns `nil` when not found or not accessible.
  """
  def get_series(%Scope{} = scope, id) do
    library_ids = Accounts.accessible_library_ids(scope)

    accessible? =
      Book
      |> join(:inner, [b], bs in BookSeries, on: bs.book_id == b.id)
      |> where([b, bs], bs.series_id == ^id)
      |> where([b, _bs], is_nil(b.missing_since))
      |> maybe_filter_book_library(library_ids)
      |> Repo.exists?()

    if accessible? do
      Series
      |> preload(^series_books_preload())
      |> Repo.get(id)
    end
  end

  @doc "Returns all series names, ordered, for autocomplete."
  def list_series_names do
    Series |> order_by(asc: :name) |> select([s], s.name) |> Repo.all()
  end

  @doc "Returns all collection names, ordered and de-duplicated, for autocomplete."
  def list_collection_names do
    Collection
    |> order_by(asc: :name)
    |> select([c], c.name)
    |> distinct(true)
    |> Repo.all()
  end

  defp series_books_preload do
    # Sequences are free-form strings (e.g. "1", "2", "10"); sort by the leading
    # numeric value when present so "10" follows "2", falling back to the raw
    # string. NULLS/non-numeric sort last.
    order =
      from(bs in BookSeries,
        join: b in Book,
        on: b.id == bs.book_id,
        where: is_nil(b.missing_since),
        order_by: [
          asc_nulls_last:
            fragment("NULLIF(substring(? from '^[0-9]+'), '')::integer", bs.sequence),
          asc_nulls_last: bs.sequence
        ]
      )

    [
      book_series:
        {order, [book: [:authors, :genres, :series, :publisher, book_narrators: :narrator]]}
    ]
  end

  defp maybe_filter_series_access(query, :all), do: query

  defp maybe_filter_series_access(query, library_ids) when is_list(library_ids) do
    where(query, [s, bs, b], b.library_id in ^library_ids)
  end

  defp maybe_filter_book_library(query, :all), do: query

  defp maybe_filter_book_library(query, library_ids) when is_list(library_ids) do
    where(query, [b, bs], b.library_id in ^library_ids)
  end

  ## Collections

  @doc """
  Lists collections in the libraries accessible to `scope`, ordered by name,
  with a lightweight preview of member books (cover + authors) for the index.
  """
  def list_collections(%Scope{} = scope) do
    library_ids = Accounts.accessible_library_ids(scope)

    Collection
    |> maybe_filter_collection_access(library_ids)
    |> order_by(asc: :name)
    |> preload(
      book_collections:
        ^from(bc in BookCollection,
          join: b in Book,
          on: b.id == bc.book_id,
          where: is_nil(b.missing_since),
          order_by: bc.position,
          preload: [book: [:authors, :genres, :series, :publisher, book_narrators: :narrator]]
        )
    )
    |> Repo.all()
  end

  @doc """
  Fetches a single collection accessible to `scope`, with its books ordered by
  position and preloaded with authors. Returns `nil` when not found/accessible.
  """
  def get_collection(%Scope{} = scope, id) do
    library_ids = Accounts.accessible_library_ids(scope)

    Collection
    |> maybe_filter_collection_access(library_ids)
    |> preload(
      book_collections:
        ^from(bc in BookCollection,
          join: b in Book,
          on: b.id == bc.book_id,
          where: is_nil(b.missing_since),
          order_by: bc.position,
          preload: [book: [:authors, :genres, :series, :publisher, book_narrators: :narrator]]
        )
    )
    |> Repo.get(id)
  end

  defp maybe_filter_collection_access(query, :all), do: query

  defp maybe_filter_collection_access(query, library_ids) when is_list(library_ids) do
    where(query, [c], c.library_id in ^library_ids)
  end

  @doc """
  Finds or creates a collection by `(library_id, name)`.
  """
  def upsert_collection(library_id, name, attrs \\ %{}) when is_binary(name) do
    name = String.trim(name)

    %Collection{}
    |> Collection.changeset(Map.merge(%{library_id: library_id, name: name}, attrs))
    |> Repo.insert(
      on_conflict: {:replace, [:description, :updated_at]},
      conflict_target: [:library_id, :name],
      returning: true
    )
    |> case do
      {:ok, collection} -> collection
      # on_conflict with returning may not repopulate on some adapters; fall back.
      {:error, _} -> Repo.get_by!(Collection, library_id: library_id, name: name)
    end
  end

  @doc """
  Replaces a collection's book membership with `book_ids`, in order (the list
  index becomes the stored `position`).
  """
  def set_collection_books(%Collection{} = collection, book_ids) when is_list(book_ids) do
    Repo.delete_all(from bc in BookCollection, where: bc.collection_id == ^collection.id)

    book_ids
    |> Enum.with_index()
    |> Enum.each(fn {book_id, index} ->
      Repo.insert!(%BookCollection{
        collection_id: collection.id,
        book_id: book_id,
        position: index
      })
    end)

    collection
  end

  @doc """
  Adds `book_id` to the end of a collection accessible to `scope`. Idempotent.
  The book must belong to the collection's library.
  """
  def add_book_to_collection(%Scope{} = scope, collection_id, book_id) do
    collection = get_collection(scope, collection_id)
    book = Repo.get(Book, book_id)

    cond do
      is_nil(collection) or is_nil(book) ->
        {:error, :not_found}

      book.library_id != collection.library_id ->
        {:error, :wrong_library}

      true ->
        next_position =
          BookCollection
          |> where([bc], bc.collection_id == ^collection.id)
          |> select([bc], coalesce(max(bc.position), -1) + 1)
          |> Repo.one()

        Repo.insert!(
          %BookCollection{
            collection_id: collection.id,
            book_id: book_id,
            position: next_position
          },
          on_conflict: :nothing,
          conflict_target: [:collection_id, :book_id]
        )

        {:ok, collection}
    end
  end

  @doc "Removes `book_id` from a collection accessible to `scope`."
  def remove_book_from_collection(%Scope{} = scope, collection_id, book_id) do
    case get_collection(scope, collection_id) do
      nil ->
        {:error, :not_found}

      collection ->
        Repo.delete_all(
          from bc in BookCollection,
            where: bc.collection_id == ^collection.id and bc.book_id == ^book_id
        )

        {:ok, collection}
    end
  end

  ## Playlists (user-scoped)

  @doc """
  Lists the scoped user's playlists, ordered by name, with their books
  preloaded (ordered by position) for previews.
  """
  def list_playlists(%Scope{user: %User{} = user} = scope) do
    playlist_books = playlist_books_preload(Accounts.accessible_library_ids(scope))

    Playlist
    |> where([p], p.user_id == ^user.id)
    |> order_by(asc: :name)
    |> preload(playlist_books: ^playlist_books)
    |> Repo.all()
  end

  def list_playlists(_scope), do: []

  @doc """
  Fetches one of the scoped user's playlists with books ordered by position.
  Returns `nil` when not found or not owned by the user.
  """
  def get_playlist(%Scope{user: %User{} = user} = scope, id) do
    playlist_books = playlist_books_preload(Accounts.accessible_library_ids(scope))

    Playlist
    |> where([p], p.user_id == ^user.id)
    |> preload(playlist_books: ^playlist_books)
    |> Repo.get(id)
  end

  def get_playlist(_scope, _id), do: nil

  defp playlist_books_preload(library_ids) do
    PlaylistBook
    |> join(:inner, [pb], b in Book, on: b.id == pb.book_id)
    |> where([_pb, b], is_nil(b.missing_since))
    |> maybe_filter_playlist_book_access(library_ids)
    |> order_by([pb], asc: pb.position)
    |> preload([pb, _b],
      book: [:authors, :genres, :series, :publisher, book_narrators: :narrator]
    )
  end

  defp maybe_filter_playlist_book_access(query, :all), do: query
  defp maybe_filter_playlist_book_access(query, []), do: where(query, [_pb, _b], false)

  defp maybe_filter_playlist_book_access(query, library_ids),
    do: where(query, [_pb, b], b.library_id in ^library_ids)

  @doc """
  Finds or creates a playlist by `(user_id, name)`.
  """
  def upsert_playlist(user_id, name, attrs \\ %{}) when is_binary(name) do
    name = String.trim(name)

    %Playlist{}
    |> Playlist.changeset(Map.merge(%{user_id: user_id, name: name}, attrs))
    |> Repo.insert(
      on_conflict: {:replace, [:description, :updated_at]},
      conflict_target: [:user_id, :name],
      returning: true
    )
    |> case do
      {:ok, playlist} -> playlist
      {:error, _} -> Repo.get_by!(Playlist, user_id: user_id, name: name)
    end
  end

  @doc "Creates an empty playlist for the scoped user."
  def create_playlist(%Scope{user: %User{} = user}, name) when is_binary(name) do
    %Playlist{}
    |> Playlist.changeset(%{user_id: user.id, name: String.trim(name)})
    |> Repo.insert()
  end

  @doc "Renames/updates a playlist owned by the scoped user."
  def update_playlist(%Scope{user: %User{} = user}, %Playlist{user_id: uid} = playlist, attrs)
      when uid == user.id do
    playlist
    |> Playlist.changeset(Map.put(attrs, "user_id", user.id))
    |> Repo.update()
  end

  @doc "Deletes a playlist owned by the scoped user."
  def delete_playlist(%Scope{user: %User{} = user}, %Playlist{user_id: uid} = playlist)
      when uid == user.id do
    Repo.delete(playlist)
  end

  @doc """
  Replaces a playlist's book membership with `book_ids`, in order (the list
  index becomes the stored `position`).
  """
  def set_playlist_books(%Playlist{} = playlist, book_ids) when is_list(book_ids) do
    Repo.delete_all(from pb in PlaylistBook, where: pb.playlist_id == ^playlist.id)

    book_ids
    |> Enum.uniq()
    |> Enum.with_index()
    |> Enum.each(fn {book_id, index} ->
      Repo.insert!(%PlaylistBook{playlist_id: playlist.id, book_id: book_id, position: index})
    end)

    playlist
  end

  @doc """
  Adds `book_id` to the end of the scoped user's playlist. Idempotent (does
  nothing if the book is already present).
  """
  def add_book_to_playlist(%Scope{user: %User{} = user}, playlist_id, book_id) do
    playlist = Repo.get_by(Playlist, id: playlist_id, user_id: user.id)

    if playlist do
      next_position =
        PlaylistBook
        |> where([pb], pb.playlist_id == ^playlist.id)
        |> select([pb], coalesce(max(pb.position), -1) + 1)
        |> Repo.one()

      Repo.insert!(
        %PlaylistBook{playlist_id: playlist.id, book_id: book_id, position: next_position},
        on_conflict: :nothing,
        conflict_target: [:playlist_id, :book_id]
      )

      {:ok, playlist}
    else
      {:error, :not_found}
    end
  end

  @doc "Removes `book_id` from the scoped user's playlist."
  def remove_book_from_playlist(%Scope{user: %User{} = user}, playlist_id, book_id) do
    playlist = Repo.get_by(Playlist, id: playlist_id, user_id: user.id)

    if playlist do
      Repo.delete_all(
        from pb in PlaylistBook,
          where: pb.playlist_id == ^playlist.id and pb.book_id == ^book_id
      )

      {:ok, playlist}
    else
      {:error, :not_found}
    end
  end
end
