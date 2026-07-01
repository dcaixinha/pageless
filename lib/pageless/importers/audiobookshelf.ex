defmodule Pageless.Importers.Audiobookshelf do
  @moduledoc """
  Imports one-time Audiobookshelf data into an already-scanned Pageless library.

  The importer uses Audiobookshelf's HTTP API as the source of truth. ABS ids are
  only used while importing; books are matched to Pageless records by normalized
  filesystem paths, optionally after applying path-prefix mappings.
  """

  import Ecto.Query, warn: false

  alias Pageless.Accounts
  alias Pageless.Importers.Audiobookshelf.Client
  alias Pageless.Library
  alias Pageless.Library.{Book, Chapter, ItemStorage, PublishedDate}
  alias Pageless.Playback.{Bookmark, ListeningSession, PlaybackProgress}
  alias Pageless.Repo

  @default_page_size 100
  @history_page_size 100

  def run(opts) do
    with {:ok, user} <- fetch_target_user(opts),
         {:ok, client} <- build_client(opts),
         {:ok, snapshot} <- fetch_snapshot(client, opts) do
      import_snapshot(snapshot,
        user: user,
        path_maps: Keyword.get(opts, :path_maps, []),
        dry_run: Keyword.get(opts, :dry_run, false),
        import_covers: Keyword.get(opts, :import_covers, true),
        include_history: Keyword.get(opts, :include_history, false),
        cover_fetcher: fn item_id -> Client.cover(client, item_id) end
      )
    end
  end

  def import_snapshot(snapshot, opts) when is_map(snapshot) do
    user = Keyword.fetch!(opts, :user)
    path_maps = Keyword.get(opts, :path_maps, [])
    dry_run = Keyword.get(opts, :dry_run, false)
    import_covers = Keyword.get(opts, :import_covers, true)
    include_history = Keyword.get(opts, :include_history, false)
    cover_fetcher = Keyword.get(opts, :cover_fetcher, fn _ -> {:error, :not_configured} end)

    books = load_books()
    items = Enum.filter(snapshot[:items] || snapshot["items"] || [], &book_item?/1)
    matches = match_items(items, books, path_maps)

    report = base_report(snapshot, matches, dry_run)

    if dry_run do
      {:ok, report}
    else
      result =
        Repo.transaction(fn ->
          {report, id_map} =
            import_matched_items(report, matches.matched, import_covers, cover_fetcher)

          report = import_progress(report, user, snapshot[:user] || snapshot["user"], id_map)
          report = import_bookmarks(report, user, snapshot[:user] || snapshot["user"], id_map)

          report =
            import_collections(
              report,
              snapshot[:collections] || snapshot["collections"] || [],
              books,
              path_maps
            )

          report =
            import_playlists(
              report,
              user,
              snapshot[:playlists] || snapshot["playlists"] || [],
              books,
              path_maps
            )

          if include_history do
            import_history(report, user, snapshot[:listening_sessions] || [], id_map)
          else
            report
          end
        end)

      if match?({:ok, _report}, result) do
        Enum.each(matches.matched, fn %{book: book} -> ItemStorage.sync_metadata(book) end)
      end

      result
    end
  end

  def match_items(items, books, path_maps) do
    folder_index = index_books_by_folder(books)
    audio_index = index_books_by_audio_file(books)

    Enum.reduce(items, %{matched: [], unmatched: [], ambiguous: []}, fn item, acc ->
      candidates = match_candidates(item, folder_index, audio_index, path_maps)

      case candidates do
        [{book, reason}] ->
          %{acc | matched: [%{item: item, book: book, reason: reason} | acc.matched]}

        [] ->
          %{acc | unmatched: [item | acc.unmatched]}

        candidates ->
          %{acc | ambiguous: [%{item: item, candidates: candidates} | acc.ambiguous]}
      end
    end)
    |> Map.update!(:matched, &Enum.reverse/1)
    |> Map.update!(:unmatched, &Enum.reverse/1)
    |> Map.update!(:ambiguous, &Enum.reverse/1)
  end

  def normalize_path(nil, _path_maps), do: nil

  def normalize_path(path, path_maps) when is_binary(path) do
    path
    |> String.replace("\\", "/")
    |> apply_path_maps(path_maps)
    |> String.trim_trailing("/")
  end

  defp fetch_target_user(opts) do
    case Keyword.get(opts, :user) do
      nil ->
        {:error, :missing_user}

      user_arg ->
        user = Accounts.get_user_by_email(user_arg) || Repo.get(Pageless.Accounts.User, user_arg)

        case user do
          nil -> {:error, {:user_not_found, user_arg}}
          user -> {:ok, user}
        end
    end
  end

  defp build_client(opts) do
    with url when is_binary(url) <- Keyword.get(opts, :url),
         token when is_binary(token) <- Keyword.get(opts, :token) do
      {:ok, Client.new(url, token)}
    else
      _ -> {:error, :missing_audiobookshelf_url_or_token}
    end
  end

  defp fetch_snapshot(client, opts) do
    include_history = Keyword.get(opts, :include_history, false)
    library_filters = Keyword.get(opts, :libraries, [])

    with {:ok, user} <- Client.me(client),
         {:ok, %{"libraries" => all_libraries}} <- Client.libraries(client),
         {:ok, libraries} <- select_libraries(all_libraries, library_filters),
         {:ok, items} <- fetch_all_items(client, libraries),
         {:ok, collections} <- fetch_collections(client, libraries),
         {:ok, playlists} <- fetch_playlists(client, libraries),
         {:ok, sessions} <- maybe_fetch_sessions(client, include_history) do
      {:ok,
       %{
         user: user,
         libraries: libraries,
         items: items,
         collections: collections,
         playlists: playlists,
         listening_sessions: sessions
       }}
    end
  end

  # Playlists are user-scoped; fetch the authed user's playlists and narrow to
  # the selected libraries.
  defp fetch_playlists(client, libraries) do
    library_ids = MapSet.new(libraries, & &1["id"])

    case Client.playlists(client) do
      {:ok, %{"playlists" => playlists}} ->
        {:ok, Enum.filter(playlists, &(&1["libraryId"] in library_ids))}

      {:ok, _} ->
        {:ok, []}

      error ->
        error
    end
  end

  defp maybe_fetch_sessions(_client, false), do: {:ok, []}
  defp maybe_fetch_sessions(client, true), do: fetch_all_listening_sessions(client)

  # Collections are fetched server-wide, then narrowed to the selected libraries.
  defp fetch_collections(client, libraries) do
    library_ids = MapSet.new(libraries, & &1["id"])

    case Client.collections(client) do
      {:ok, %{"collections" => collections}} ->
        {:ok, Enum.filter(collections, &(&1["libraryId"] in library_ids))}

      {:ok, _} ->
        {:ok, []}

      error ->
        error
    end
  end

  @doc """
  Filters the Audiobookshelf `libraries` list down to those requested via
  `filters` (library names, case-insensitive, or ids).

  Returns `{:ok, libraries}` with all libraries when `filters` is empty, the
  matching subset otherwise, or `{:error, {:unknown_libraries, names}}` when a
  requested filter matches no library.
  """
  def select_libraries(libraries, []), do: {:ok, libraries}

  def select_libraries(libraries, filters) do
    wanted = MapSet.new(filters, &String.downcase(String.trim(&1)))

    selected =
      Enum.filter(libraries, fn library ->
        id = library["id"]
        name = library["name"]

        (is_binary(id) and String.downcase(id) in wanted) or
          (is_binary(name) and String.downcase(name) in wanted)
      end)

    matched =
      MapSet.new(
        Enum.flat_map(selected, fn library ->
          [library["id"], library["name"]]
          |> Enum.reject(&(!is_binary(&1)))
          |> Enum.map(&String.downcase/1)
        end)
      )

    case MapSet.to_list(MapSet.difference(wanted, matched)) do
      [] -> {:ok, selected}
      unknown -> {:error, {:unknown_libraries, Enum.sort(unknown)}}
    end
  end

  defp fetch_all_items(client, libraries) do
    libraries
    |> Enum.filter(&(&1["mediaType"] == "book"))
    |> Enum.reduce_while({:ok, []}, fn library, {:ok, acc} ->
      case fetch_library_items(client, library["id"], 0, []) do
        {:ok, items} -> {:cont, {:ok, acc ++ items}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, items} -> fetch_expanded_items(client, items)
      error -> error
    end)
  end

  defp fetch_library_items(client, library_id, page, acc) do
    with {:ok, %{"results" => results} = body} <-
           Client.library_items(client, library_id, page, @default_page_size) do
      total = body["total"] || length(acc) + length(results)
      next_acc = acc ++ results

      if length(next_acc) >= total or results == [] do
        {:ok, next_acc}
      else
        fetch_library_items(client, library_id, page + 1, next_acc)
      end
    end
  end

  defp fetch_expanded_items(client, items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case Client.item(client, item["id"]) do
        {:ok, expanded} -> {:cont, {:ok, [expanded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, expanded} -> {:ok, Enum.reverse(expanded)}
      error -> error
    end
  end

  defp fetch_all_listening_sessions(client, page \\ 0, acc \\ []) do
    with {:ok, %{"sessions" => sessions} = body} <-
           Client.listening_sessions(client, page, @history_page_size) do
      total = body["total"] || length(acc) + length(sessions)
      next_acc = acc ++ sessions

      if length(next_acc) >= total or sessions == [] do
        {:ok, next_acc}
      else
        fetch_all_listening_sessions(client, page + 1, next_acc)
      end
    end
  end

  defp load_books do
    Book
    |> preload([
      :authors,
      :series,
      :genres,
      :chapters,
      :audio_files,
      :publisher,
      book_narrators: :narrator
    ])
    |> Repo.all()
  end

  defp base_report(snapshot, matches, dry_run) do
    %{
      dry_run: dry_run,
      totals: %{
        abs_libraries: length(snapshot[:libraries] || snapshot["libraries"] || []),
        abs_items: length(snapshot[:items] || snapshot["items"] || []),
        abs_collections: length(snapshot[:collections] || snapshot["collections"] || []),
        abs_playlists: length(snapshot[:playlists] || snapshot["playlists"] || []),
        matched: length(matches.matched),
        unmatched: length(matches.unmatched),
        ambiguous: length(matches.ambiguous)
      },
      imported: %{
        metadata: 0,
        covers: 0,
        progress: 0,
        bookmarks: 0,
        collections: 0,
        playlists: 0,
        history: 0
      },
      unmatched: Enum.map(matches.unmatched, &item_summary/1),
      ambiguous: Enum.map(matches.ambiguous, &ambiguous_summary/1)
    }
  end

  defp import_matched_items(report, matches, import_covers, cover_fetcher) do
    Enum.reduce(matches, {report, %{}}, fn match, {report, id_map} ->
      item = match.item
      book = match.book

      {book, metadata_imported?} = fill_blank_metadata(book, item)
      {book, cover_imported?} = maybe_import_cover(book, item, import_covers, cover_fetcher)

      id_map = put_item_mappings(id_map, item, book.id)

      report =
        report
        |> inc_if(:metadata, metadata_imported?)
        |> inc_if(:covers, cover_imported?)

      {report, id_map}
    end)
  end

  defp fill_blank_metadata(%Book{} = book, item) do
    meta = get_in(item, ["media", "metadata"]) || %{}

    attrs =
      %{}
      |> put_if_blank(book, :title, text(meta["title"]))
      |> put_if_blank(book, :subtitle, text(meta["subtitle"]))
      |> put_if_blank(book, :description, text(meta["description"]))
      |> put_if_blank(book, :published_date, published_date(meta))
      |> put_if_blank(book, :isbn, text(meta["isbn"]))
      |> put_if_blank(book, :asin, text(meta["asin"]))
      |> put_if_blank(book, :language, text(meta["language"]))

    {book, changed?} = update_book_attrs(book, attrs)
    authors_changed? = add_missing_authors(book, authors(meta))
    narrators_changed? = add_missing_narrators(book, narrators(meta))
    publisher_changed? = add_missing_publisher(book, text(meta["publisher"]))
    series_changed? = add_missing_series(book, series(meta))
    genres_changed? = add_missing_genres(book, genres(meta))
    chapters_changed? = replace_chapters_if_blank(book, get_in(item, ["media", "chapters"]) || [])

    changed? =
      changed? or authors_changed? or narrators_changed? or publisher_changed? or series_changed? or
        genres_changed? or chapters_changed?

    {Library.get_book!(book.id), changed?}
  end

  defp update_book_attrs(book, attrs) when map_size(attrs) == 0, do: {book, false}

  defp update_book_attrs(book, attrs) do
    updated = book |> Book.details_changeset(attrs) |> Repo.update!()
    {updated, true}
  end

  defp put_if_blank(attrs, book, field, value) do
    if blank?(Map.get(book, field)) and not blank?(value) do
      Map.put(attrs, field, value)
    else
      attrs
    end
  end

  defp add_missing_authors(_book, []), do: false

  defp add_missing_authors(book, names) do
    existing = book.authors |> Enum.map(&String.downcase(&1.name)) |> MapSet.new()
    missing = Enum.reject(names, &(String.downcase(&1) in existing))

    if missing == [] do
      false
    else
      authors = book.authors ++ Enum.map(missing, &Library.upsert_author/1)

      book
      |> Repo.preload(:authors)
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_assoc(:authors, authors)
      |> Repo.update!()

      true
    end
  end

  defp add_missing_narrators(_book, []), do: false

  defp add_missing_narrators(book, names) do
    current_names = Enum.map(book.book_narrators, & &1.narrator.name)
    existing = current_names |> Enum.map(&String.downcase/1) |> MapSet.new()
    missing = Enum.reject(names, &(String.downcase(&1) in existing))

    if missing == [] do
      false
    else
      {:ok, :ok} = Library.replace_book_narrators(book, current_names ++ missing)
      true
    end
  end

  defp add_missing_publisher(_book, nil), do: false
  defp add_missing_publisher(%Book{publisher: %Pageless.Library.Publisher{}}, _name), do: false

  defp add_missing_publisher(book, name) do
    publisher = Library.upsert_publisher(name)

    book
    |> Repo.preload(:publisher)
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(:publisher, publisher)
    |> Repo.update!()

    true
  end

  defp add_missing_series(_book, []), do: false

  defp add_missing_series(book, entries) do
    book = Repo.preload(book, :book_series)

    existing =
      Map.new(book.book_series, fn bs -> {bs.series_id, bs.sequence} end)

    new_entries =
      Enum.reject(entries, fn entry ->
        series = Library.upsert_series(entry.name)
        Map.get(existing, series.id, :__missing__) == entry[:sequence]
      end)

    if new_entries == [] do
      false
    else
      Library.set_book_series(book, entries)
      true
    end
  end

  defp add_missing_genres(_book, []), do: false

  defp add_missing_genres(book, names) do
    existing = book.genres |> Enum.map(&String.downcase(&1.name)) |> MapSet.new()
    missing = Enum.reject(names, &(String.downcase(&1) in existing))

    if missing == [] do
      false
    else
      genres = book.genres ++ Enum.map(missing, &Library.upsert_genre/1)

      book
      |> Repo.preload(:genres)
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_assoc(:genres, genres)
      |> Repo.update!()

      true
    end
  end

  defp replace_chapters_if_blank(_book, []), do: false

  defp replace_chapters_if_blank(book, chapters) do
    if useful_chapters?(book.chapters) do
      false
    else
      rows =
        chapters
        |> Enum.map(fn ch ->
          %{
            title: text(ch["title"]),
            start_seconds: to_float(ch["start"]),
            end_seconds: to_float(ch["end"])
          }
        end)
        |> Enum.filter(&(&1.end_seconds >= &1.start_seconds))
        |> Enum.sort_by(& &1.start_seconds)

      Repo.delete_all(from c in Chapter, where: c.book_id == ^book.id)

      rows
      |> Enum.with_index()
      |> Enum.each(fn {row, index} ->
        %Chapter{book_id: book.id}
        |> Chapter.changeset(Map.put(row, :index, index))
        |> Repo.insert!()
      end)

      rows != []
    end
  end

  defp useful_chapters?([]), do: false

  defp useful_chapters?([chapter]) do
    not blank?(chapter.title) and chapter.title != "Chapter 1"
  end

  defp useful_chapters?(_chapters), do: true

  defp maybe_import_cover(book, item, true, cover_fetcher) do
    if blank?(book.cover_path) do
      case cover_fetcher.(item["id"]) do
        {:ok, body, content_type} when is_binary(body) ->
          {:ok, dest} = ItemStorage.store_cover(book, body, ext_from_content_type(content_type))
          book = Repo.update!(Ecto.Changeset.change(book, cover_path: dest))
          {book, true}

        _ ->
          {book, false}
      end
    else
      {book, false}
    end
  end

  defp maybe_import_cover(book, _item, _import_covers, _cover_fetcher), do: {book, false}

  defp import_progress(report, _user, nil, _id_map), do: report

  defp import_progress(report, user, abs_user, id_map) do
    abs_user
    |> Map.get("mediaProgress", [])
    |> Enum.reduce(report, fn progress, report ->
      case map_progress(progress, user.id, id_map) do
        nil -> report
        attrs -> inc_if(report, :progress, upsert_progress(attrs))
      end
    end)
  end

  defp map_progress(progress, user_id, id_map) do
    book_id = id_map[progress["libraryItemId"]]

    if book_id do
      last_played_at = to_datetime(progress["lastUpdate"]) || DateTime.utc_now(:second)

      %{
        user_id: user_id,
        book_id: book_id,
        current_seconds: to_float(progress["currentTime"]),
        duration_seconds: to_float(progress["duration"]),
        finished_at: finished_at(progress, last_played_at),
        started_at: to_datetime(progress["startedAt"]) || last_played_at,
        last_played_at: last_played_at
      }
    end
  end

  defp upsert_progress(attrs) do
    now = DateTime.utc_now(:second)

    existing =
      PlaybackProgress
      |> where([p], p.user_id == ^attrs.user_id and p.book_id == ^attrs.book_id)
      |> Repo.one()

    if apply_progress?(attrs, existing) do
      row =
        attrs
        |> Map.merge(%{
          deleted_at: nil,
          inserted_at: (existing && existing.inserted_at) || now,
          updated_at: now
        })

      Repo.insert_all(
        PlaybackProgress,
        [row],
        on_conflict:
          {:replace,
           [
             :current_seconds,
             :duration_seconds,
             :finished_at,
             :started_at,
             :last_played_at,
             :deleted_at,
             :updated_at
           ]},
        conflict_target: [:user_id, :book_id]
      )

      true
    else
      false
    end
  end

  defp import_bookmarks(report, _user, nil, _id_map), do: report

  defp import_bookmarks(report, user, abs_user, id_map) do
    abs_user
    |> Map.get("bookmarks", [])
    |> Enum.reduce(report, fn bookmark, report ->
      case map_bookmark(bookmark, user.id, id_map) do
        nil -> report
        attrs -> inc_if(report, :bookmarks, upsert_bookmark(attrs))
      end
    end)
  end

  defp map_bookmark(bookmark, user_id, id_map) do
    book_id = id_map[bookmark["libraryItemId"]]

    if book_id do
      inserted_at = to_datetime(bookmark["createdAt"]) || DateTime.utc_now(:second)

      %{
        id: Ecto.UUID.generate(),
        user_id: user_id,
        book_id: book_id,
        position_seconds: to_float(bookmark["time"]),
        note: bookmark["title"] |> text() |> truncate(500),
        deleted_at: nil,
        inserted_at: inserted_at,
        updated_at: inserted_at
      }
    end
  end

  defp upsert_bookmark(attrs) do
    existing =
      Bookmark
      |> where(
        [b],
        b.user_id == ^attrs.user_id and b.book_id == ^attrs.book_id and
          b.position_seconds == ^attrs.position_seconds
      )
      |> Repo.one()

    case existing do
      nil ->
        Repo.insert_all(Bookmark, [attrs])
        true

      %Bookmark{} = bookmark ->
        bookmark
        |> Ecto.Changeset.change(note: attrs.note, deleted_at: nil, updated_at: attrs.updated_at)
        |> Repo.update!()

        true
    end
  end

  # Imports Audiobookshelf collections. Each collection's books are matched to
  # Pageless books by path (reusing the item matcher); the collection is created
  # in the Pageless library its matched books belong to. Collections with no
  # matched books are skipped.
  defp import_collections(report, collections, books, path_maps) do
    Enum.reduce(collections, report, fn collection, report ->
      inc_if(report, :collections, import_collection(collection, books, path_maps))
    end)
  end

  defp import_collection(collection, books, path_maps) do
    name = text(collection["name"])
    items = Enum.filter(collection["books"] || [], &book_item?/1)
    matched = match_items(items, books, path_maps).matched
    matched_books = Enum.map(matched, & &1.book)

    with false <- is_nil(name),
         [_ | _] <- matched_books,
         library_id when not is_nil(library_id) <- collection_library_id(matched_books) do
      # Keep only books that belong to the resolved library (collections are
      # library-scoped); this also covers the rare cross-library ABS collection.
      book_ids =
        matched_books
        |> Enum.filter(&(&1.library_id == library_id))
        |> Enum.map(& &1.id)
        |> Enum.uniq()

      Library.upsert_collection(library_id, name, %{description: text(collection["description"])})
      |> Library.set_collection_books(book_ids)

      true
    else
      _ -> false
    end
  end

  # Resolve the target Pageless library as the one most matched books belong to.
  defp collection_library_id(matched_books) do
    matched_books
    |> Enum.frequencies_by(& &1.library_id)
    |> Enum.max_by(fn {_lib, count} -> count end, fn -> {nil, 0} end)
    |> elem(0)
  end

  # Imports Audiobookshelf playlists for the target Pageless `user`. Each
  # playlist item's `libraryItem` is matched to a Pageless book by path,
  # preserving order. Playlists with no matched books are skipped.
  defp import_playlists(report, user, playlists, books, path_maps) do
    scope = %Pageless.Accounts.Scope{user: user}

    Enum.reduce(playlists, report, fn playlist, report ->
      inc_if(report, :playlists, import_playlist(scope, playlist, books, path_maps))
    end)
  end

  defp import_playlist(scope, playlist, books, path_maps) do
    name = text(playlist["name"])

    # Preserve playlist order: match each item in turn to a Pageless book.
    book_ids =
      (playlist["items"] || [])
      |> Enum.map(& &1["libraryItem"])
      |> Enum.filter(&(is_map(&1) and book_item?(&1)))
      |> Enum.flat_map(fn item ->
        case match_items([item], books, path_maps).matched do
          [%{book: book} | _] -> [book.id]
          [] -> []
        end
      end)
      |> Enum.uniq()

    with false <- is_nil(name),
         [_ | _] <- book_ids do
      scope.user.id
      |> Library.upsert_playlist(name, %{description: text(playlist["description"])})
      |> Library.set_playlist_books(book_ids)

      true
    else
      _ -> false
    end
  end

  defp import_history(report, user, sessions, id_map) do
    sessions
    |> Enum.reduce(report, fn session, report ->
      case map_session(session, user.id, id_map) do
        nil -> report
        attrs -> inc_if(report, :history, upsert_session(attrs))
      end
    end)
  end

  defp map_session(session, user_id, id_map) do
    book_id = id_map[session["libraryItemId"]] || id_map[session["bookId"]]

    if not is_nil(book_id) and valid_uuid?(session["id"]) do
      updated_at = to_datetime(session["updatedAt"]) || DateTime.utc_now(:second)

      %{
        id: session["id"],
        user_id: user_id,
        book_id: book_id,
        title: text(session["displayTitle"]),
        authors: text(session["displayAuthor"]),
        play_method: session["playMethod"] |> to_string() |> text(),
        device_info: device_info(session["deviceInfo"]),
        started_at: to_datetime(session["startedAt"]) || updated_at,
        updated_at_client: updated_at,
        ended_at: updated_at,
        time_listened_seconds: session["timeListening"] |> to_int() |> max(0),
        last_position_seconds: session["currentTime"] |> to_float() |> max(0.0),
        duration_seconds: session["duration"] |> to_float() |> max(0.0)
      }
    end
  end

  defp upsert_session(attrs) do
    now = DateTime.utc_now(:second)
    row = Map.merge(attrs, %{inserted_at: now, updated_at: now})

    Repo.insert_all(
      ListeningSession,
      [row],
      on_conflict:
        {:replace,
         [
           :title,
           :authors,
           :play_method,
           :device_info,
           :started_at,
           :updated_at_client,
           :ended_at,
           :time_listened_seconds,
           :last_position_seconds,
           :duration_seconds,
           :updated_at
         ]},
      conflict_target: [:id]
    )

    true
  end

  defp put_item_mappings(id_map, item, book_id) do
    [item["id"], item["oldLibraryItemId"], get_in(item, ["media", "id"])]
    |> Enum.reject(&blank?/1)
    |> Enum.reduce(id_map, &Map.put(&2, &1, book_id))
  end

  defp match_candidates(item, folder_index, audio_index, path_maps) do
    folder_matches = item_paths(item) |> matches_from_index(folder_index, path_maps, :folder_path)

    audio_matches =
      audio_paths(item) |> matches_from_index(audio_index, path_maps, :audio_file_path)

    (folder_matches ++ audio_matches)
    |> Enum.uniq_by(fn {book, _reason} -> book.id end)
  end

  defp matches_from_index(paths, index, path_maps, reason) do
    paths
    |> Enum.map(&normalize_path(&1, path_maps))
    |> Enum.reject(&blank?/1)
    |> Enum.flat_map(fn path -> Enum.map(Map.get(index, path, []), &{&1, reason}) end)
  end

  defp item_paths(item), do: [item["path"], item["relPath"]]

  defp audio_paths(item) do
    item
    |> get_in(["media", "audioFiles"])
    |> List.wrap()
    |> Enum.flat_map(fn audio ->
      metadata = audio["metadata"] || %{}
      [metadata["path"], metadata["relPath"]]
    end)
  end

  defp index_books_by_folder(books) do
    Enum.reduce(books, %{}, fn book, acc ->
      Map.update(acc, normalize_path(book.folder_path, []), [book], &[book | &1])
    end)
  end

  defp index_books_by_audio_file(books) do
    Enum.reduce(books, %{}, fn book, acc ->
      Enum.reduce(book.audio_files, acc, fn audio, acc ->
        Map.update(acc, normalize_path(audio.path, []), [book], &[book | &1])
      end)
    end)
  end

  defp apply_path_maps(path, path_maps) do
    path_maps
    |> Enum.sort_by(fn {from, _to} -> String.length(from) end, :desc)
    |> Enum.find_value(path, fn {from, to} ->
      from = String.trim_trailing(from, "/")
      to = String.trim_trailing(to, "/")

      if path == from or String.starts_with?(path, from <> "/") do
        to <> String.replace_prefix(path, from, "")
      end
    end)
  end

  defp item_summary(item) do
    %{id: item["id"], path: item["path"], title: get_in(item, ["media", "metadata", "title"])}
  end

  defp ambiguous_summary(%{item: item, candidates: candidates}) do
    %{
      item: item_summary(item),
      candidates:
        Enum.map(candidates, fn {book, reason} -> %{book_id: book.id, reason: reason} end)
    }
  end

  defp book_item?(item),
    do: item["mediaType"] == "book" or get_in(item, ["media", "libraryItemId"])

  defp authors(%{"authors" => authors}) when is_list(authors) do
    authors
    |> Enum.map(fn
      %{"name" => name} -> text(name)
      name when is_binary(name) -> text(name)
      _ -> nil
    end)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp authors(_meta), do: []

  defp series(%{"series" => series}) when is_list(series) do
    series
    |> Enum.map(fn
      %{"name" => name} = entry -> series_entry(name, entry["sequence"])
      name when is_binary(name) -> series_entry_from_string(name)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    # A book in a series must have a sequence number; skip numberless entries.
    |> Enum.reject(&is_nil(&1.sequence))
    |> Enum.uniq_by(& &1.name)
  end

  defp series(_meta), do: []

  defp series_entry(name, sequence) do
    case text(name) do
      nil -> nil
      name -> %{name: name, sequence: text(to_string(sequence))}
    end
  end

  # Minified metadata joins name and sequence as "Name #5".
  defp series_entry_from_string(str) do
    case String.split(str, " #", parts: 2) do
      [name, sequence] -> series_entry(name, sequence)
      [name] -> series_entry(name, nil)
    end
  end

  defp genres(%{"genres" => genres}) when is_list(genres) do
    genres
    |> Enum.map(fn
      %{"name" => name} -> name
      name when is_binary(name) -> name
      _ -> nil
    end)
    |> Enum.flat_map(&split_genre/1)
    |> Enum.uniq()
  end

  defp genres(%{"genre" => genre}) when is_binary(genre) do
    genre
    |> split_genre()
    |> Enum.uniq()
  end

  defp genres(_meta), do: []

  # Mirrors `Pageless.Library.Scanner`'s genre splitting so genres imported from
  # Audiobookshelf (e.g. "History:World:Civilization") are broken into the same
  # individual genres as a local scan.
  defp split_genre(name) when is_binary(name) do
    name
    |> String.split([",", ";", "/", ":"], trim: true)
    |> Enum.map(&text/1)
    |> Enum.reject(&blank?/1)
  end

  defp split_genre(_), do: []

  defp narrators(%{"narrators" => narrators}) when is_list(narrators) do
    narrators
    |> Enum.map(fn
      %{"name" => name} -> text(name)
      name when is_binary(name) -> text(name)
      _ -> nil
    end)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp narrators(%{"narratorName" => narrator}) do
    case text(narrator) do
      nil -> []
      name -> [name]
    end
  end

  defp narrators(_meta), do: []

  defp finished_at(%{"isFinished" => true} = progress, fallback) do
    to_datetime(progress["finishedAt"]) || fallback
  end

  defp finished_at(_progress, _fallback), do: nil

  # Decides whether the incoming Audiobookshelf progress should overwrite the
  # existing Pageless row. Ongoing mobile sync uses strict last-write-wins by
  # timestamp, but a one-time import treats ABS as authoritative in two cases:
  #
  #   * the local row was soft-deleted (tombstone) -> always revive/overwrite,
  #   * ABS marks the book finished and the local row is not finished ->
  #     the explicit "finished" intent wins regardless of timestamp.
  #
  # Otherwise it falls back to last-write-wins by `last_played_at`.
  defp apply_progress?(_attrs, nil), do: true
  defp apply_progress?(_attrs, %{deleted_at: deleted_at}) when not is_nil(deleted_at), do: true

  defp apply_progress?(%{finished_at: finished_at}, %{finished_at: nil})
       when not is_nil(finished_at),
       do: true

  defp apply_progress?(attrs, existing),
    do: not stale?(attrs.last_played_at, existing.last_played_at)

  defp stale?(_incoming, nil), do: false
  defp stale?(incoming, stored), do: DateTime.compare(incoming, stored) == :lt

  defp to_datetime(nil), do: nil

  defp to_datetime(%DateTime{} = dt), do: DateTime.truncate(dt, :second)

  defp to_datetime(value) when is_integer(value) do
    value |> DateTime.from_unix!(:millisecond) |> DateTime.truncate(:second)
  end

  defp to_datetime(value) when is_float(value), do: value |> trunc() |> to_datetime()

  defp to_datetime(value) when is_binary(value) do
    cond do
      match?({_int, ""}, Integer.parse(value)) ->
        {int, ""} = Integer.parse(value)
        to_datetime(int)

      true ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _} -> DateTime.truncate(dt, :second)
          _ -> nil
        end
    end
  end

  defp to_datetime(_), do: nil

  defp to_float(nil), do: 0.0
  defp to_float(value) when is_number(value), do: value * 1.0

  defp to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> 0.0
    end
  end

  defp to_int(nil), do: 0
  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  # Audiobookshelf stores the granular value in either `publishedDate` or (on
  # some servers/imports) `publishedYear`, which may be a full date string.
  defp published_date(meta) do
    PublishedDate.parse(meta["publishedDate"] || meta["publishedYear"])
  end

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(value) when is_number(value), do: to_string(value)
  defp text(_), do: nil

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp truncate(nil, _max), do: nil
  defp truncate(value, max), do: String.slice(value, 0, max)

  defp ext_from_content_type(nil), do: "jpg"
  defp ext_from_content_type("image/png" <> _), do: "png"
  defp ext_from_content_type("image/webp" <> _), do: "webp"
  defp ext_from_content_type(_), do: "jpg"

  defp device_info(nil), do: "Unknown device"
  defp device_info(value) when is_binary(value), do: value
  defp device_info(value), do: Jason.encode!(value)

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.dump(value))
  defp valid_uuid?(_), do: false

  defp inc_if(report, _key, false), do: report
  defp inc_if(report, key, true), do: update_in(report, [:imported, key], &(&1 + 1))
end
