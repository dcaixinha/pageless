defmodule PagelessWeb.LibraryLive.Show do
  use PagelessWeb, :live_view

  alias Pageless.Accounts
  alias Pageless.Audible
  alias Pageless.Library
  alias Pageless.Library.Chapters
  alias Pageless.Library.Events
  alias Pageless.Playback
  alias Pageless.Format
  alias PagelessWeb.AudioController
  alias PagelessWeb.PlayerLive

  # Descriptions longer than this (in characters) are collapsed behind a
  # "Read more" toggle.
  @description_clamp 280
  @audible_client Application.compile_env(:pageless, :audible_client, Audible)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    book = Library.get_book!(socket.assigns.current_scope, id)
    progress = Playback.get_progress(socket.assigns.current_scope, book.id)
    bookmarks = Playback.list_bookmarks(socket.assigns.current_scope, book.id)
    user = socket.assigns.current_scope.user
    settings = Accounts.get_player_settings(user)

    if connected?(socket) do
      Events.subscribe(socket.assigns.current_scope)
      Phoenix.PubSub.subscribe(Pageless.PubSub, PlayerLive.state_topic(user.id))
      PlayerLive.request_state(user.id)
    end

    {:ok,
     socket
     |> assign(progress: progress)
     |> assign(bookmarks: bookmarks)
     |> assign(
       player_settings: settings,
       date_format: settings.date_format,
       time_format: settings.time_format
     )
     |> assign(can_update?: Accounts.user_can?(user, :can_update))
     |> assign(now_playing?: false, now_paused?: false, show_edit: false, edit_tab: "details")
     |> assign(player_position: nil, player_position_seen?: false)
     |> assign(bookmarks_expanded?: true, chapters_expanded?: true)
     |> assign(
       cover_url: "",
       chapter_edits: [],
       show_chapter_lookup: false,
       chapter_lookup_form: chapter_lookup_form(book),
       chapter_lookup_loading?: false,
       chapter_lookup_result: nil,
       chapter_lookup_error: nil,
       selected_bookmark: nil,
       bookmark_preview_token: nil,
       all_series: [],
       all_collections: [],
       all_narrators: [],
       all_publishers: [],
       selected_series: [],
       selected_collections: [],
       selected_narrators: [],
       series_query: "",
       collections_query: "",
       narrators_query: "",
       series_error: nil,
       playlists: [],
       book_playlist_ids: MapSet.new()
     )
     |> allow_upload(:cover,
       accept: ~w(.jpg .jpeg .png .webp),
       max_entries: 1,
       max_file_size: 15_000_000
     )
     |> assign_book(book)
     |> assign_current_chapter_from_progress()}
  end

  # Assigns the book and all of its derived presentation assigns.
  defp assign_book(socket, book) do
    socket
    |> assign(
      page_title: book.title,
      book: book,
      description_html: sanitize_description(book.description),
      description_long?: long_description?(book.description),
      expanded?: false
    )
  end

  defp sanitize_description(nil), do: nil
  defp sanitize_description(desc), do: Phoenix.HTML.raw(HtmlSanitizeEx.basic_html(desc))

  defp long_description?(nil), do: false
  defp long_description?(desc), do: String.length(desc) > @description_clamp

  defp current_chapter_index(socket, true, position, position_seen?) when is_number(position) do
    seconds = display_current_seconds(socket.assigns.progress, position, position_seen?)
    Chapters.current_index(socket.assigns.book.chapters, seconds)
  end

  defp current_chapter_index(socket, _active?, _position, _position_seen?) do
    progress_chapter_index(socket.assigns.book, socket.assigns.progress)
  end

  defp assign_current_chapter_from_progress(socket) do
    assign(
      socket,
      current_chapter_index: progress_chapter_index(socket.assigns.book, socket.assigns.progress)
    )
  end

  defp progress_chapter_index(_book, nil), do: nil

  # A finished book has no "current" chapter (don't highlight the first one when
  # there's no saved position, e.g. imported as finished from Audiobookshelf).
  defp progress_chapter_index(_book, %{finished_at: finished_at}) when not is_nil(finished_at),
    do: nil

  defp progress_chapter_index(book, %{current_seconds: seconds}) when is_number(seconds) do
    Chapters.current_index(book.chapters, seconds)
  end

  defp progress_chapter_index(_book, _progress), do: nil

  defp grouped_bookmarks(bookmarks, chapters) do
    bookmarks
    |> Enum.group_by(&bookmark_chapter_index(&1, chapters))
    |> Enum.map(fn {index, bookmarks} ->
      %{
        key: index || :unknown,
        title: bookmark_group_title(index, chapters),
        bookmarks: bookmarks
      }
    end)
    |> Enum.sort_by(fn %{key: key} -> if key == :unknown, do: -1, else: key end)
  end

  defp bookmark_chapter_index(_bookmark, []), do: nil

  defp bookmark_chapter_index(bookmark, chapters) do
    Chapters.current_index(chapters, bookmark.position_seconds)
  end

  defp bookmark_group_title(nil, _chapters), do: "Bookmarks"

  defp bookmark_group_title(index, chapters) do
    case Enum.at(chapters, index) do
      nil -> "Bookmarks"
      chapter -> chapter.title || "Chapter #{chapter.index + 1}"
    end
  end

  defp bookmark_chapter_title(bookmark, chapters) do
    bookmark
    |> bookmark_chapter_index(chapters)
    |> bookmark_group_title(chapters)
  end

  @impl true
  def handle_info({:player_state, %{book_id: book_id} = state}, socket) do
    active? = book_id == socket.assigns.book.id
    playing = Map.get(state, :playing, false)
    position = Map.get(state, :position)
    player_position = if active? and is_number(position), do: position, else: nil

    player_position_seen? =
      active? and (socket.assigns.player_position_seen? or (is_number(position) and position > 0))

    current_index = current_chapter_index(socket, active?, player_position, player_position_seen?)

    {:noreply,
     assign(socket,
       now_playing?: active? and playing,
       now_paused?: active? and not playing,
       current_chapter_index: current_index,
       player_position: player_position,
       player_position_seen?: player_position_seen?
     )}
  end

  def handle_info(
        {:catalog_changed, %{upserted_book_ids: upserted_ids, missing_book_ids: missing_ids}},
        socket
      ) do
    book_id = socket.assigns.book.id

    if book_id in upserted_ids or book_id in missing_ids do
      {:noreply, refresh_book(socket, book_id)}
    else
      {:noreply, socket}
    end
  end

  defp refresh_book(socket, book_id) do
    case Library.get_book(socket.assigns.current_scope, book_id) do
      nil ->
        push_navigate(socket, to: ~p"/library")

      book ->
        expanded? = socket.assigns.expanded?

        socket
        |> assign_book(book)
        |> assign(
          expanded?: expanded?,
          progress: Playback.get_progress(socket.assigns.current_scope, book_id),
          bookmarks: Playback.list_bookmarks(socket.assigns.current_scope, book_id)
        )
        |> assign_current_chapter_from_progress()
    end
  end

  @impl true
  def handle_event("toggle_playback", _params, socket) do
    if socket.assigns.now_playing? or socket.assigns.now_paused? do
      Phoenix.PubSub.broadcast(
        Pageless.PubSub,
        PlayerLive.topic(socket.assigns.current_scope.user.id),
        :toggle_playback
      )
    else
      PagelessWeb.PlayerLive.play(socket.assigns.current_scope.user.id, socket.assigns.book.id)
    end

    {:noreply, socket}
  end

  def handle_event("play_chapter", %{"start" => start}, socket) do
    start = String.to_float(ensure_float_string(start))

    PagelessWeb.PlayerLive.play(
      socket.assigns.current_scope.user.id,
      socket.assigns.book.id,
      start
    )

    {:noreply, socket}
  end

  def handle_event("toggle_description", _params, socket) do
    {:noreply, assign(socket, expanded?: not socket.assigns.expanded?)}
  end

  def handle_event("toggle_bookmarks", _params, socket) do
    {:noreply, assign(socket, bookmarks_expanded?: not socket.assigns.bookmarks_expanded?)}
  end

  def handle_event("toggle_chapters", _params, socket) do
    {:noreply, assign(socket, chapters_expanded?: not socket.assigns.chapters_expanded?)}
  end

  def handle_event("mark_finished", _params, socket) do
    progress =
      Playback.mark_finished(
        socket.assigns.current_scope,
        socket.assigns.book.id,
        socket.assigns.book.duration_seconds
      )

    {:noreply, socket |> assign(progress: progress) |> assign_current_chapter_from_progress()}
  end

  def handle_event("mark_not_finished", _params, socket) do
    progress = Playback.mark_not_finished(socket.assigns.current_scope, socket.assigns.book.id)
    {:noreply, socket |> assign(progress: progress) |> assign_current_chapter_from_progress()}
  end

  def handle_event("remove_progress", _params, socket) do
    Playback.delete_progress(socket.assigns.current_scope, socket.assigns.book.id)

    {:noreply,
     assign(socket,
       progress: nil,
       current_chapter_index: nil,
       player_position: nil,
       player_position_seen?: false
     )}
  end

  def handle_event("preview_bookmark", %{"id" => id}, socket) do
    bookmark = Enum.find(socket.assigns.bookmarks, &(&1.id == id))

    if bookmark do
      token =
        AudioController.sign_token(
          PagelessWeb.Endpoint,
          socket.assigns.current_scope.user.id,
          socket.assigns.book.id
        )

      {:noreply, assign(socket, selected_bookmark: bookmark, bookmark_preview_token: token)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_bookmark_preview", _params, socket) do
    {:noreply, assign(socket, selected_bookmark: nil, bookmark_preview_token: nil)}
  end

  def handle_event(
        "play_selected_bookmark",
        _params,
        %{assigns: %{selected_bookmark: nil}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event("play_selected_bookmark", _params, socket) do
    PagelessWeb.PlayerLive.play(
      socket.assigns.current_scope.user.id,
      socket.assigns.book.id,
      socket.assigns.selected_bookmark.position_seconds
    )

    {:noreply, assign(socket, selected_bookmark: nil, bookmark_preview_token: nil)}
  end

  def handle_event("open_edit", _params, socket) do
    if socket.assigns.can_update? do
      {:noreply,
       socket
       |> assign(show_edit: true, edit_tab: "details", cover_url: "")
       |> assign_edit_form()
       |> assign_edit_tags()
       |> assign_playlist_state()
       |> load_chapter_edits()}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to edit books.")}
    end
  end

  def handle_event("close_edit", _params, %{assigns: %{show_chapter_lookup: true}} = socket) do
    {:noreply, close_chapter_lookup(socket)}
  end

  def handle_event("close_edit", _params, socket) do
    {:noreply, assign(socket, show_edit: false)}
  end

  def handle_event("edit_tab", %{"tab" => "chapters"}, socket) do
    {:noreply, socket |> assign(edit_tab: "chapters") |> load_chapter_edits()}
  end

  def handle_event("edit_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, edit_tab: tab)}
  end

  def handle_event("validate_cover", %{"cover_url" => url}, socket) do
    {:noreply, assign(socket, cover_url: url)}
  end

  def handle_event("validate_cover", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("upload_cover", _params, socket) do
    if not socket.assigns.can_update? do
      {:noreply, put_flash(socket, :error, "You do not have permission to edit books.")}
    else
      results =
        consume_uploaded_entries(socket, :cover, fn %{path: path}, _entry ->
          # Return `{:ok, term}` so the entry is consumed regardless of DB result.
          Library.set_cover_from_file(socket.assigns.book, path)
        end)

      case results do
        [_book] ->
          book = Library.get_book!(socket.assigns.book.id)

          {:noreply,
           socket
           |> assign_book(book)
           |> put_flash(:info, "Cover updated.")}

        _ ->
          {:noreply, put_flash(socket, :error, "Please choose an image to upload.")}
      end
    end
  end

  def handle_event("submit_cover_url", %{"cover_url" => url}, socket) do
    if not socket.assigns.can_update? do
      {:noreply, put_flash(socket, :error, "You do not have permission to edit books.")}
    else
      url = String.trim(url)

      if url == "" do
        {:noreply, socket}
      else
        case Library.set_cover_from_url(socket.assigns.book, url) do
          {:ok, _book} ->
            book = Library.get_book!(socket.assigns.book.id)

            {:noreply,
             socket
             |> assign_book(book)
             |> assign(cover_url: "")
             |> put_flash(:info, "Cover updated.")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not fetch an image from that URL.")}
        end
      end
    end
  end

  def handle_event(
        "update_chapter_field",
        %{"id" => id, "field" => field, "value" => value},
        socket
      ) do
    chapters =
      Enum.map(socket.assigns.chapter_edits, fn ch ->
        if ch.id == id do
          update_chapter_edit(ch, field, value)
        else
          ch
        end
      end)

    {:noreply, assign(socket, chapter_edits: chapters)}
  end

  def handle_event("remove_chapter", %{"id" => id}, socket) do
    chapters = Enum.reject(socket.assigns.chapter_edits, &(&1.id == id))
    {:noreply, assign(socket, chapter_edits: chapters)}
  end

  def handle_event("remove_all_chapters", _params, socket) do
    {:noreply, assign(socket, chapter_edits: [])}
  end

  def handle_event("open_chapter_lookup", _params, socket) do
    if socket.assigns.can_update? do
      {:noreply,
       assign(socket,
         show_chapter_lookup: true,
         chapter_lookup_form: chapter_lookup_form(socket.assigns.book),
         chapter_lookup_loading?: false,
         chapter_lookup_result: nil,
         chapter_lookup_error: nil
       )}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to edit books.")}
    end
  end

  def handle_event("close_chapter_lookup", _params, socket) do
    {:noreply, close_chapter_lookup(socket)}
  end

  def handle_event("reset_chapter_lookup", _params, socket) do
    {:noreply, assign(socket, chapter_lookup_result: nil, chapter_lookup_error: nil)}
  end

  def handle_event("lookup_audible_chapters", %{"lookup" => params}, socket) do
    cond do
      not socket.assigns.can_update? ->
        {:noreply, put_flash(socket, :error, "You do not have permission to edit books.")}

      socket.assigns.chapter_lookup_loading? ->
        {:noreply, socket}

      true ->
        asin = params["asin"] || ""
        region = params["region"] || "us"
        remove_branding? = params["remove_branding"] in ["true", "on"]

        socket =
          assign(socket,
            chapter_lookup_form: to_form(params, as: :lookup),
            chapter_lookup_loading?: true,
            chapter_lookup_result: nil,
            chapter_lookup_error: nil
          )

        {:noreply,
         start_async(socket, :audible_chapter_lookup, fn ->
           with {:ok, result} <- @audible_client.fetch_chapters(asin, region) do
             {:ok, if(remove_branding?, do: Audible.remove_branding(result), else: result)}
           end
         end)}
    end
  end

  def handle_event("apply_audible_chapters", _params, socket) do
    case socket.assigns.chapter_lookup_result do
      nil ->
        {:noreply, socket}

      result ->
        chapters = audible_chapter_edits(result.chapters, socket.assigns.book.duration_seconds)

        {:noreply,
         socket
         |> assign(chapter_edits: chapters)
         |> close_chapter_lookup()}
    end
  end

  def handle_event("map_audible_chapter_titles", _params, socket) do
    case socket.assigns.chapter_lookup_result do
      nil ->
        {:noreply, socket}

      result ->
        titles = Enum.map(result.chapters, & &1.title)

        chapters =
          socket.assigns.chapter_edits
          |> Enum.with_index()
          |> Enum.map(fn {chapter, index} ->
            case Enum.at(titles, index) do
              nil -> chapter
              title -> %{chapter | title: title}
            end
          end)

        {:noreply,
         socket
         |> assign(chapter_edits: chapters)
         |> close_chapter_lookup()}
    end
  end

  def handle_event("add_chapter", _params, socket) do
    edits = socket.assigns.chapter_edits
    new = new_chapter(List.last(edits))
    {:noreply, assign(socket, chapter_edits: edits ++ [new])}
  end

  def handle_event("insert_chapter_below", %{"id" => id}, socket) do
    edits = socket.assigns.chapter_edits

    chapters =
      case Enum.find_index(edits, &(&1.id == id)) do
        nil ->
          edits ++ [new_chapter(List.last(edits))]

        idx ->
          List.insert_at(edits, idx + 1, new_chapter(Enum.at(edits, idx)))
      end

    {:noreply, assign(socket, chapter_edits: chapters)}
  end

  def handle_event("play_chapter_edit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.chapter_edits, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      chapter ->
        start = Format.parse_hms(chapter.start) || 0.0

        PagelessWeb.PlayerLive.play(
          socket.assigns.current_scope.user.id,
          socket.assigns.book.id,
          start,
          preview: true
        )

        {:noreply, socket}
    end
  end

  def handle_event("save_chapters", _params, socket) do
    if not socket.assigns.can_update? do
      {:noreply, put_flash(socket, :error, "You do not have permission to edit books.")}
    else
      entries =
        Enum.map(socket.assigns.chapter_edits, fn ch ->
          %{title: ch.title, start_seconds: ch.start_seconds}
        end)

      case Library.replace_chapters(socket.assigns.book, entries) do
        {:ok, book} ->
          {:noreply,
           socket
           |> assign(show_edit: false)
           |> assign_book(book)
           |> put_flash(:info, "Chapters updated.")}

        _ ->
          {:noreply, put_flash(socket, :error, "Could not save chapters.")}
      end
    end
  end

  def handle_event("validate_edit", %{"book" => params}, socket) do
    changeset =
      socket.assigns.book
      |> Library.change_book(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, edit_form: to_form(changeset))}
  end

  def handle_event("save_edit", %{"book" => params}, socket) do
    if not socket.assigns.can_update? do
      {:noreply, put_flash(socket, :error, "You do not have permission to edit books.")}
    else
      {pending_narrator, params} = Map.pop(params, "pending_narrators", "")

      selected_narrators =
        case String.trim(pending_narrator) do
          "" -> socket.assigns.selected_narrators
          name -> socket.assigns.selected_narrators ++ [name]
        end

      params =
        params
        |> Map.put("series", serialize_series(socket.assigns.selected_series))
        |> Map.put("collections", Enum.join(socket.assigns.selected_collections, ", "))
        |> Map.put("narrators", selected_narrators)

      case Library.update_book(socket.assigns.book, params) do
        {:ok, _updated} ->
          book = Library.get_book!(socket.assigns.book.id)

          {:noreply,
           socket
           |> assign(show_edit: false)
           |> assign_book(book)
           |> put_flash(:info, "Book updated.")}

        {:error, changeset} ->
          {:noreply, assign(socket, edit_form: to_form(changeset))}
      end
    end
  end

  def handle_event("tag_filter", %{"field" => field, "value" => value}, socket) do
    socket = assign(socket, query_key(field), value)

    # Clear any prior series error as soon as the user resumes typing.
    socket = if field == "series", do: assign(socket, series_error: nil), else: socket

    {:noreply, socket}
  end

  def handle_event("tag_add_series", %{"name" => name}, socket) do
    name = String.trim(name)

    socket =
      cond do
        name == "" ->
          socket

        not valid_series_entry?(name) ->
          assign(socket,
            series_query: name,
            series_error: ~s(Series must include a number, e.g. "#{series_base(name)} #1".)
          )

        true ->
          {base, sequence} = split_sequence(name)

          selected =
            socket.assigns.selected_series
            |> Enum.reject(&(String.downcase(&1.name) == String.downcase(base)))
            |> Kernel.++([%{name: base, sequence: sequence}])

          socket
          |> assign(selected_series: selected, series_query: "", series_error: nil)
          |> push_event("tag_input_cleared", %{field: "series"})
      end

    {:noreply, socket}
  end

  def handle_event("tag_remove_series", %{"name" => name}, socket) do
    selected = Enum.reject(socket.assigns.selected_series, &(&1.name == name))
    {:noreply, assign(socket, selected_series: selected)}
  end

  # Selecting an existing series still needs a per-book number, so prefill the
  # input with "Name #" and let the user type the sequence.
  def handle_event("tag_prefill_series", %{"name" => name}, socket) do
    value = "#{name} #"

    {:noreply,
     socket
     |> assign(series_query: value, series_error: nil)
     |> push_event("tag_input_set", %{field: "series", value: value})}
  end

  def handle_event("tag_add_collection", %{"name" => name}, socket) do
    name = String.trim(name)

    socket =
      if name == "" do
        socket
      else
        selected =
          socket.assigns.selected_collections
          |> Enum.reject(&(String.downcase(&1) == String.downcase(name)))
          |> Kernel.++([name])

        socket
        |> assign(selected_collections: selected, collections_query: "")
        |> push_event("tag_input_cleared", %{field: "collections"})
      end

    {:noreply, socket}
  end

  def handle_event("tag_remove_collection", %{"name" => name}, socket) do
    selected = Enum.reject(socket.assigns.selected_collections, &(&1 == name))
    {:noreply, assign(socket, selected_collections: selected)}
  end

  def handle_event("tag_add_narrator", %{"name" => name}, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, socket}
    else
      selected =
        socket.assigns.selected_narrators
        |> Enum.reject(&(String.downcase(&1) == String.downcase(name)))
        |> Kernel.++([name])

      {:noreply,
       socket
       |> assign(selected_narrators: selected, narrators_query: "")
       |> push_event("tag_input_cleared", %{field: "narrators"})}
    end
  end

  def handle_event("tag_remove_narrator", %{"name" => name}, socket) do
    {:noreply,
     assign(socket, selected_narrators: List.delete(socket.assigns.selected_narrators, name))}
  end

  # Add/remove this book to/from a playlist immediately (playlists are actions,
  # not part of the book's save changeset).
  def handle_event("add_to_playlist", %{"playlist_id" => ""}, socket), do: {:noreply, socket}

  def handle_event("add_to_playlist", %{"playlist_id" => playlist_id}, socket) do
    case Library.add_book_to_playlist(
           socket.assigns.current_scope,
           playlist_id,
           socket.assigns.book.id
         ) do
      {:ok, _} ->
        {:noreply, socket |> assign_playlist_state() |> put_flash(:info, "Added to playlist.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not add to playlist.")}
    end
  end

  def handle_event("remove_from_playlist", %{"playlist_id" => playlist_id}, socket) do
    Library.remove_book_from_playlist(
      socket.assigns.current_scope,
      playlist_id,
      socket.assigns.book.id
    )

    {:noreply, assign_playlist_state(socket)}
  end

  def handle_event("create_playlist_with_book", %{"name" => name}, socket) do
    scope = socket.assigns.current_scope

    with trimmed when trimmed != "" <- String.trim(name),
         {:ok, playlist} <- Library.create_playlist(scope, trimmed),
         {:ok, _} <- Library.add_book_to_playlist(scope, playlist.id, socket.assigns.book.id) do
      {:noreply, socket |> assign_playlist_state() |> put_flash(:info, "Added to new playlist.")}
    else
      "" -> {:noreply, put_flash(socket, :error, "Please enter a playlist name.")}
      _ -> {:noreply, put_flash(socket, :error, "Could not create playlist.")}
    end
  end

  @impl true
  def handle_async(:audible_chapter_lookup, {:ok, {:ok, result}}, socket) do
    if socket.assigns.show_chapter_lookup do
      {:noreply,
       assign(socket,
         chapter_lookup_loading?: false,
         chapter_lookup_result: result,
         chapter_lookup_error: nil
       )}
    else
      {:noreply, assign(socket, chapter_lookup_loading?: false)}
    end
  end

  def handle_async(:audible_chapter_lookup, {:ok, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       chapter_lookup_loading?: false,
       chapter_lookup_error: audible_lookup_error(reason)
     )}
  end

  def handle_async(:audible_chapter_lookup, {:exit, {:shutdown, :cancel}}, socket) do
    {:noreply, assign(socket, chapter_lookup_loading?: false)}
  end

  def handle_async(:audible_chapter_lookup, {:exit, _reason}, socket) do
    {:noreply,
     assign(socket,
       chapter_lookup_loading?: false,
       chapter_lookup_error: "Audible chapter lookup failed. Please try again."
     )}
  end

  defp assign_edit_form(socket) do
    changeset = Library.change_book(socket.assigns.book)
    assign(socket, edit_form: to_form(changeset))
  end

  # Initializes the pill/autocomplete state for normalized metadata fields
  # fields from the book's current memberships.
  defp assign_edit_tags(socket) do
    book = socket.assigns.book

    selected_series =
      Enum.map(book.book_series, fn bs ->
        %{name: bs.series.name, sequence: bs.sequence}
      end)

    selected_collections = Enum.map(book.book_collections, & &1.collection.name)
    selected_narrators = Enum.map(book.book_narrators, & &1.narrator.name)

    assign(socket,
      all_series: Library.list_series_names(),
      all_collections: Library.list_collection_names(),
      all_narrators: Library.list_narrator_names(socket.assigns.current_scope),
      all_publishers: Library.list_publisher_names(socket.assigns.current_scope),
      selected_series: selected_series,
      selected_collections: selected_collections,
      selected_narrators: selected_narrators,
      series_query: "",
      collections_query: "",
      narrators_query: "",
      series_error: nil
    )
  end

  # Loads the user's playlists and which of them contain this book, for the
  # "Add to playlist" control in the edit modal.
  defp assign_playlist_state(socket) do
    scope = socket.assigns.current_scope
    playlists = Library.list_playlists(scope)
    book_id = socket.assigns.book.id

    member_ids =
      playlists
      |> Enum.filter(fn pl -> Enum.any?(pl.playlist_books, &(&1.book_id == book_id)) end)
      |> MapSet.new(& &1.id)

    assign(socket,
      playlists: Enum.map(playlists, &%{id: &1.id, name: &1.name}),
      book_playlist_ids: member_ids
    )
  end

  defp query_key("series"), do: :series_query
  defp query_key("collections"), do: :collections_query
  defp query_key("narrators"), do: :narrators_query

  defp serialize_series(selected) do
    Enum.map_join(selected, ", ", fn
      %{name: name, sequence: seq} when is_binary(seq) and seq != "" -> "#{name} ##{seq}"
      %{name: name} -> name
    end)
  end

  # Splits a "Name #3" entry into {"Name", "3"}.
  defp split_sequence(entry) do
    case String.split(entry, " #", parts: 2) do
      [name, sequence] -> {String.trim(name), String.trim(sequence)}
      [name] -> {String.trim(name), nil}
    end
  end

  # A new series entry must have a non-empty name and a numeric "#<n>" sequence,
  # e.g. "Uma Aventura #1".
  defp valid_series_entry?(entry) do
    {base, sequence} = split_sequence(entry)
    base != "" and is_binary(sequence) and Regex.match?(~r/^\d+(\.\d+)?$/, sequence)
  end

  # The name portion of an entry (for building the hint message).
  defp series_base(entry) do
    {base, _seq} = split_sequence(entry)
    if base == "", do: "Series", else: base
  end

  # Existing series/collection names matching the query and not already selected.
  defp tag_suggestions(all_names, selected_names, query) do
    q = query |> String.trim() |> String.downcase()

    if q == "" do
      # Don't surface the whole list on open/empty input; only suggest while
      # the user is actively typing.
      []
    else
      selected_down = MapSet.new(selected_names, &String.downcase/1)

      all_names
      |> Enum.reject(&(String.downcase(&1) in selected_down))
      |> Enum.filter(&String.contains?(String.downcase(&1), q))
      |> Enum.take(8)
    end
  end

  # Whether the trimmed query is a brand-new value (offer "Create new").
  defp new_tag?(all_names, selected_names, query) do
    trimmed = String.trim(query)

    trimmed != "" and
      String.downcase(trimmed) not in Enum.map(all_names ++ selected_names, &String.downcase/1)
  end

  # Builds a blank chapter row starting one second after the reference row (or
  # at 00:00:00 when there is none).
  defp new_chapter(reference) do
    start =
      case reference do
        %{start: start} -> Format.hms((Format.parse_hms(start) || 0.0) + 1)
        _ -> "00:00:00"
      end

    %{
      id: Ecto.UUID.generate(),
      start: start,
      start_seconds: Format.parse_hms(start) || 0.0,
      title: ""
    }
  end

  defp chapter_lookup_form(book) do
    to_form(
      %{
        "asin" => book.asin || "",
        "region" => "us",
        "remove_branding" => "false"
      },
      as: :lookup
    )
  end

  defp close_chapter_lookup(socket) do
    socket =
      if socket.assigns.chapter_lookup_loading? do
        cancel_async(socket, :audible_chapter_lookup)
      else
        socket
      end

    assign(socket,
      show_chapter_lookup: false,
      chapter_lookup_loading?: false,
      chapter_lookup_result: nil,
      chapter_lookup_error: nil
    )
  end

  defp audible_chapter_edits(chapters, duration) do
    duration = duration || 0.0

    chapters
    |> Enum.filter(&(duration <= 0 or &1.start_seconds < duration))
    |> Enum.map(fn chapter ->
      %{
        id: Ecto.UUID.generate(),
        start: Format.hms(chapter.start_seconds),
        start_seconds: chapter.start_seconds,
        title: chapter.title
      }
    end)
  end

  defp audible_lookup_error(:invalid_asin),
    do: "Enter a valid 10-character Audible ASIN for the selected region."

  defp audible_lookup_error(:invalid_region), do: "Select a supported Audible region."

  defp audible_lookup_error(:not_found),
    do: "No Audible chapters were found for that ASIN and region."

  defp audible_lookup_error(:rate_limited),
    do: "Audible lookup is busy. Please try again shortly."

  defp audible_lookup_error(_reason),
    do: "Audible chapter lookup is unavailable. Please try again."

  defp update_chapter_edit(chapter, "start", value) do
    %{chapter | start: value, start_seconds: Format.parse_hms(value) || 0.0}
  end

  defp update_chapter_edit(chapter, "title", value), do: %{chapter | title: value}
  defp update_chapter_edit(chapter, _field, _value), do: chapter

  # Loads the book's chapters into editable form state (HH:MM:SS strings).
  defp load_chapter_edits(socket) do
    edits =
      Enum.map(socket.assigns.book.chapters, fn ch ->
        %{
          id: ch.id,
          start: Format.hms(ch.start_seconds),
          start_seconds: ch.start_seconds,
          title: ch.title || ""
        }
      end)

    assign(socket, chapter_edits: edits)
  end

  defp ensure_float_string(s) do
    if String.contains?(s, "."), do: s, else: s <> ".0"
  end

  defp play_button_label(true, _paused?, _progress), do: "Pause"
  defp play_button_label(_playing?, true, _progress), do: "Play"

  defp play_button_label(false, false, progress),
    do: if(resume_seconds(progress) > 0, do: "Resume", else: "Play")

  defp resume_seconds(nil), do: 0.0
  defp resume_seconds(%{current_seconds: s}), do: s

  defp progress_pct(progress, duration, player_position, position_seen?)

  defp progress_pct(_progress, duration, _player_position, _position_seen?)
       when duration in [nil, 0, 0.0], do: 0

  defp progress_pct(progress, duration, player_position, position_seen?) do
    current = display_current_seconds(progress, player_position, position_seen?)
    min(round(current / duration * 100), 100)
  end

  defp progress_fraction(progress, duration, player_position, position_seen?)

  defp progress_fraction(progress, duration, _player_position, _position_seen?)
       when duration in [nil, 0, 0.0],
       do: if(finished?(progress), do: 100, else: 0)

  defp progress_fraction(progress, duration, player_position, position_seen?) do
    current = display_current_seconds(progress, player_position, position_seen?)

    # A finished book fills the bar even with no saved position (e.g. imported
    # as finished from Audiobookshelf). A live player position still wins so an
    # actively-scrubbing bar reflects the real spot.
    if finished?(progress) and not showing_live_position?(player_position, position_seen?) do
      100
    else
      (current / duration * 100)
      |> max(0)
      |> min(100)
    end
  end

  defp showing_live_position?(player_position, position_seen?),
    do: is_number(player_position) and position_seen?

  defp remaining_duration(progress, duration, player_position, position_seen?)

  defp remaining_duration(progress, duration, player_position, position_seen?)
       when is_number(duration) do
    current = display_current_seconds(progress, player_position, position_seen?)

    duration
    |> Kernel.-(current)
    |> max(0.0)
    |> Format.duration()
  end

  defp remaining_duration(_progress, _duration, _player_position, _position_seen?), do: "0m"

  defp display_current_seconds(progress, player_position, position_seen?)
       when is_number(player_position) do
    saved = resume_seconds(progress)

    if not position_seen? and player_position <= 0 and saved > 0 do
      saved
    else
      max(player_position, 0.0)
    end
  end

  defp display_current_seconds(progress, _player_position, _position_seen?),
    do: resume_seconds(progress)

  defp current_chapter_title(book, current_chapter_index) do
    case Enum.at(book.chapters, current_chapter_index || -1) do
      nil -> nil
      chapter -> chapter.title || "Chapter #{chapter.index + 1}"
    end
  end

  defp finished?(progress), do: Playback.finished?(progress)

  # Cover URL with a cache-busting version derived from the book's updated_at,
  # so a freshly-changed cover is shown immediately.
  defp cover_url(book) do
    version =
      case book.updated_at do
        %DateTime{} = dt -> DateTime.to_unix(dt)
        _ -> 0
      end

    ~p"/books/#{book.id}/cover?v=#{version}"
  end

  defp series_label(%{series: %{name: name}, sequence: sequence}) do
    case sequence do
      seq when is_binary(seq) and seq != "" -> "#{name} ##{seq}"
      _ -> name
    end
  end

  # Pill label for a selected series (`%{name, sequence}`): "Name #seq".
  defp series_pill(%{name: name, sequence: sequence}) do
    case sequence do
      seq when is_binary(seq) and seq != "" -> "#{name} ##{seq}"
      _ -> name
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} socket={@socket} active={:library}>
      <div class="max-w-4xl space-y-8">
        <.link
          navigate={~p"/library"}
          class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content"
        >
          <.icon name="hero-arrow-left" class="size-4" /> Back to library
        </.link>

        <div class="flex flex-col gap-8 md:flex-row md:items-stretch">
          <div class="shrink-0">
            <div
              id="book-cover-frame"
              class="aspect-square w-56 overflow-hidden rounded-2xl bg-base-300 shadow-lg md:w-64"
            >
              <img
                src={cover_url(@book)}
                alt={@book.title}
                class="size-full object-cover"
                onerror="this.style.visibility='hidden'"
              />
            </div>
          </div>

          <div id="book-hero-details" class="flex min-w-0 flex-1 flex-col">
            <div class="flex items-start justify-between gap-4">
              <div class="min-w-0">
                <h1 class="text-3xl font-bold leading-tight">{@book.title}</h1>
                <p :if={@book.subtitle} class="mt-1 text-lg text-base-content/70">
                  {@book.subtitle}
                </p>
              </div>
              <button
                :if={@can_update?}
                type="button"
                phx-click="open_edit"
                title="Edit details"
                aria-label="Edit details"
                class="inline-flex shrink-0 items-center gap-2 rounded-full border border-base-300 px-3 py-2 text-sm font-medium text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
              >
                <.icon name="hero-pencil-square" class="size-5" /> Edit
              </button>
            </div>

            <dl class="mt-4 grid grid-cols-2 gap-x-6 gap-y-2 text-sm">
              <div :if={@book.authors != []}>
                <dt class="text-base-content/50">By</dt>
                <dd class="font-medium">
                  <span :for={{author, i} <- Enum.with_index(@book.authors)}>
                    <span :if={i > 0}>, </span><.link
                      id={"book-author-link-#{author.id}"}
                      navigate={~p"/library?#{%{"authors" => [author.id]}}"}
                      class="rounded-sm transition hover:text-primary hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
                    >{author.name}</.link>
                  </span>
                </dd>
              </div>
              <div :if={@book.book_narrators != []}>
                <dt class="text-base-content/50">Narrated by</dt>
                <dd class="font-medium">
                  <span :for={{book_narrator, i} <- Enum.with_index(@book.book_narrators)}>
                    <span :if={i > 0}>, </span><.link
                      id={"book-narrator-link-#{book_narrator.narrator.id}"}
                      navigate={~p"/library?#{%{"narrators" => [book_narrator.narrator.id]}}"}
                      class="rounded-sm transition hover:text-primary hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
                    >{book_narrator.narrator.name}</.link>
                  </span>
                </dd>
              </div>
              <div :if={@book.book_series != []}>
                <dt class="text-base-content/50">Series</dt>
                <dd class="font-medium">
                  <span :for={{bs, i} <- Enum.with_index(@book.book_series)}>
                    <span :if={i > 0}>, </span><.link
                      id={"book-series-link-#{bs.series.id}"}
                      navigate={~p"/library?#{%{"series" => [bs.series.id]}}"}
                      class="rounded-sm transition hover:text-primary hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
                    >{series_label(bs)}</.link>
                  </span>
                </dd>
              </div>
              <div :if={@book.genres != []}>
                <dt class="text-base-content/50">Genres</dt>
                <dd class="font-medium">
                  <span :for={{genre, i} <- Enum.with_index(@book.genres)}>
                    <span :if={i > 0}>, </span><.link
                      id={"book-genre-link-#{genre.id}"}
                      navigate={~p"/library?#{%{"genres" => [genre.id]}}"}
                      class="rounded-sm transition hover:text-primary hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
                    >{genre.name}</.link>
                  </span>
                </dd>
              </div>
              <div :if={@book.publisher}>
                <dt class="text-base-content/50">Publisher</dt>
                <dd class="font-medium">
                  <.link
                    id={"book-publisher-link-#{@book.publisher.id}"}
                    navigate={~p"/library?#{%{"publishers" => [@book.publisher.id]}}"}
                    class="rounded-sm transition hover:text-primary hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
                  >{@book.publisher.name}</.link>
                </dd>
              </div>
              <div :if={@book.language}>
                <dt class="text-base-content/50">Language</dt>
                <dd class="font-medium">
                  <.link
                    id="book-language-link"
                    navigate={~p"/library?#{%{"languages" => [@book.language]}}"}
                    class="rounded-sm transition hover:text-primary hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
                  >{@book.language}</.link>
                </dd>
              </div>
              <div :if={@book.published_date}>
                <dt class="text-base-content/50">Published</dt>
                <dd class="font-medium">{@book.published_date.year}</dd>
              </div>
              <div>
                <dt class="text-base-content/50">Duration</dt>
                <dd class="font-medium">{Format.duration(@book.duration_seconds)}</dd>
              </div>
            </dl>

            <div id="book-hero-actions" class="mt-6 flex items-center gap-3 md:mt-auto md:pt-4">
              <button
                type="button"
                phx-click="toggle_playback"
                class="inline-flex items-center gap-2 rounded-full bg-primary px-6 py-3 text-sm font-semibold text-primary-content shadow transition hover:opacity-90"
              >
                <.icon
                  name={if @now_playing?, do: "hero-pause-solid", else: "hero-play-solid"}
                  class="size-5"
                />
                {play_button_label(@now_playing?, @now_paused?, @progress)}
              </button>

              <button
                :if={finished?(@progress)}
                type="button"
                phx-click="mark_not_finished"
                title="Mark as not finished"
                class="inline-flex items-center gap-2 rounded-full border border-base-300 px-4 py-3 text-sm font-medium hover:bg-base-200 transition"
              >
                <.icon name="hero-arrow-uturn-left" class="size-4" /> Mark as not finished
              </button>
              <button
                :if={not finished?(@progress)}
                type="button"
                phx-click="mark_finished"
                title="Mark as finished"
                class="inline-flex items-center gap-2 rounded-full border border-base-300 px-4 py-3 text-sm font-medium hover:bg-base-200 transition"
              >
                <.icon name="hero-check" class="size-4" /> Mark as finished
              </button>
            </div>
          </div>
        </div>

        <div
          :if={@progress}
          class="relative rounded-2xl border border-[color:var(--pg-border)] bg-[color:var(--pg-surface)] px-5 py-4 text-center text-sm shadow-sm"
        >
          <div class="mx-auto max-w-lg space-y-1.5">
            <%= if finished?(@progress) do %>
              <div class="inline-flex items-center gap-2 font-bold text-success">
                <.icon name="hero-check-circle-solid" class="size-4" /> Finished
                <span :if={@progress.finished_at} class="font-normal text-base-content/60">
                  {Format.date(@progress.finished_at, @date_format)}
                </span>
              </div>
            <% else %>
              <div class="font-bold">
                Your Progress: {progress_pct(
                  @progress,
                  @book.duration_seconds,
                  @player_position,
                  @player_position_seen?
                )}%
              </div>
              <div class="text-sm text-[color:var(--pg-muted)]">
                {remaining_duration(
                  @progress,
                  @book.duration_seconds,
                  @player_position,
                  @player_position_seen?
                )} remaining
              </div>
              <div
                :if={current_chapter_title(@book, @current_chapter_index)}
                class="truncate text-sm text-[color:var(--pg-muted)]"
              >
                Current chapter: {current_chapter_title(@book, @current_chapter_index)}
              </div>
            <% end %>

            <div :if={@progress.started_at} class="text-sm text-[color:var(--pg-muted)]">
              Started {Format.date(@progress.started_at, @date_format)}
            </div>

            <div class="pt-2">
              <div class="h-1.5 overflow-hidden rounded-full bg-[color:var(--pg-tab)]">
                <div
                  class="h-full rounded-full bg-primary"
                  style={"width: #{progress_fraction(@progress, @book.duration_seconds, @player_position, @player_position_seen?)}%"}
                >
                </div>
              </div>
            </div>
          </div>

          <button
            type="button"
            phx-click="remove_progress"
            data-confirm="Remove your progress for this book? This resets it to unstarted."
            title="Remove progress"
            aria-label="Remove progress"
            class="absolute right-3 top-3 rounded-full p-1.5 text-base-content/50 transition hover:bg-error/10 hover:text-error"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <div :if={@book.description} class="space-y-2">
          <h2 class="text-lg font-semibold text-base-content">Description</h2>
          <div
            class={[
              "prose prose-sm max-w-none text-base-content/80",
              (not @expanded? and @description_long?) && "line-clamp-3"
            ]}
            phx-no-format
          >{@description_html}</div>
          <button
            :if={@description_long?}
            type="button"
            phx-click="toggle_description"
            class="inline-flex items-center gap-1 text-sm font-medium text-primary hover:underline"
          >
            {if @expanded?, do: "Read less", else: "Read more"}
            <.icon
              name={if @expanded?, do: "hero-chevron-up", else: "hero-chevron-down"}
              class="size-4"
            />
          </button>
        </div>

        <div class="space-y-2">
          <button
            type="button"
            phx-click="toggle_bookmarks"
            class="flex w-full items-center justify-between gap-3 text-left"
          >
            <h2 class="text-lg font-semibold">Bookmarks ({length(@bookmarks)})</h2>
            <.icon
              name={if @bookmarks_expanded?, do: "hero-chevron-up", else: "hero-chevron-down"}
              class="size-5 text-base-content/60"
            />
          </button>

          <div
            :if={@bookmarks_expanded? and @bookmarks == []}
            class="rounded-xl border border-dashed border-[color:var(--pg-border)] p-6 text-center text-sm text-base-content/50"
          >
            No bookmarks yet.
          </div>

          <div :if={@bookmarks_expanded? and @bookmarks != []} class="space-y-3">
            <div
              :for={group <- grouped_bookmarks(@bookmarks, @book.chapters)}
              id={"bookmark-group-#{group.key}"}
              class="space-y-2"
            >
              <h3 class="truncate text-sm font-semibold text-primary">{group.title}</h3>
              <ul class="overflow-hidden rounded-xl border border-[color:var(--pg-border)]">
                <li
                  :for={bookmark <- group.bookmarks}
                  id={"bookmark-#{bookmark.id}"}
                  phx-click="preview_bookmark"
                  phx-value-id={bookmark.id}
                  class="flex cursor-pointer items-start gap-3 border-b border-[color:var(--pg-border)] px-4 py-3 text-sm transition last:border-b-0 hover:bg-[color:var(--pg-tab-active)]"
                >
                  <.icon name="hero-bookmark" class="mt-0.5 size-4 shrink-0 text-primary" />
                  <div class="min-w-0 flex-1">
                    <div class="truncate font-medium">{bookmark.note || "Bookmark"}</div>
                    <div class="text-xs text-[color:var(--pg-muted)]">
                      {Format.clock(bookmark.position_seconds)}
                    </div>
                  </div>
                </li>
              </ul>
            </div>
          </div>
        </div>

        <div :if={@book.chapters != []} class="space-y-2">
          <button
            type="button"
            phx-click="toggle_chapters"
            class="flex w-full items-center justify-between gap-3 text-left"
          >
            <h2 class="text-lg font-semibold">Chapters ({length(@book.chapters)})</h2>
            <.icon
              name={if @chapters_expanded?, do: "hero-chevron-up", else: "hero-chevron-down"}
              class="size-5 text-base-content/60"
            />
          </button>
          <ul
            :if={@chapters_expanded?}
            class="overflow-hidden rounded-xl border border-[color:var(--pg-border)]"
          >
            <li class="grid grid-cols-[minmax(0,1fr)_12.5rem] items-center border-b border-[color:var(--pg-border)] px-4 py-2 text-xs font-semibold text-[color:var(--pg-muted)]">
              <span class="pl-7">Title</span>
              <div class="ml-3 grid grid-cols-[5.5rem_1rem_5rem] items-center pr-6 tabular-nums">
                <span class="text-left">Start</span>
                <span aria-hidden="true" class="text-center"></span>
                <span class="text-right">Duration</span>
              </div>
            </li>
            <li
              :for={{chapter, index} <- Enum.with_index(@book.chapters)}
              class={[
                "relative grid grid-cols-[minmax(0,1fr)_12.5rem] items-center border-b border-[color:var(--pg-border)] px-4 py-3 text-sm transition last:border-b-0",
                if(index == @current_chapter_index,
                  do:
                    "bg-primary/15 font-semibold before:absolute before:inset-y-0 before:left-0 before:w-1 before:bg-primary",
                  else: "hover:bg-[color:var(--pg-tab-active)]"
                )
              ]}
            >
              <button
                type="button"
                phx-click="play_chapter"
                phx-value-start={chapter.start_seconds}
                class="flex min-w-0 items-center gap-3 text-left"
              >
                <.icon
                  name={
                    if index == @current_chapter_index,
                      do: "hero-speaker-wave-solid",
                      else: "hero-play"
                  }
                  class={[
                    "size-4",
                    if(index == @current_chapter_index,
                      do: "text-primary",
                      else: "text-base-content/40"
                    )
                  ]}
                />
                <span class="truncate">{chapter.title || "Chapter #{chapter.index + 1}"}</span>
              </button>
              <div class="ml-3 grid shrink-0 grid-cols-[5.5rem_1rem_5rem] items-center pr-6 text-base-content/40 tabular-nums">
                <span class="text-left">{Format.clock(chapter.start_seconds)}</span>
                <span aria-hidden="true" class="text-center">·</span>
                <span class="text-right">{Format.short_duration(chapter_duration(chapter))}</span>
              </div>
            </li>
          </ul>
        </div>
      </div>

      <.edit_modal
        :if={@show_edit}
        form={@edit_form}
        book={@book}
        tab={@edit_tab}
        uploads={@uploads}
        cover_url={@cover_url}
        chapters={@chapter_edits}
        show_chapter_lookup={@show_chapter_lookup}
        chapter_lookup_form={@chapter_lookup_form}
        chapter_lookup_loading?={@chapter_lookup_loading?}
        chapter_lookup_result={@chapter_lookup_result}
        chapter_lookup_error={@chapter_lookup_error}
        all_series={@all_series}
        all_collections={@all_collections}
        all_narrators={@all_narrators}
        all_publishers={@all_publishers}
        selected_series={@selected_series}
        selected_collections={@selected_collections}
        selected_narrators={@selected_narrators}
        series_query={@series_query}
        collections_query={@collections_query}
        narrators_query={@narrators_query}
        series_error={@series_error}
        playlists={@playlists}
        book_playlist_ids={@book_playlist_ids}
      />

      <.bookmark_preview_modal
        :if={@selected_bookmark}
        book={@book}
        bookmark={@selected_bookmark}
        token={@bookmark_preview_token}
        chapter_title={bookmark_chapter_title(@selected_bookmark, @book.chapters)}
        settings={@player_settings}
      />
    </Layouts.app>
    """
  end

  attr :book, :map, required: true
  attr :bookmark, :map, required: true
  attr :token, :string, required: true
  attr :chapter_title, :string, required: true
  attr :settings, :map, required: true

  defp bookmark_preview_modal(assigns) do
    ~H"""
    <div
      id="bookmark-preview-modal"
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      phx-window-keydown="close_bookmark_preview"
      phx-key="escape"
    >
      <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" phx-click="close_bookmark_preview" />

      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="bookmark-preview-title"
        class="relative w-full max-w-lg rounded-2xl border border-[color:var(--pg-border)] bg-[color:var(--pg-surface)] p-5 shadow-2xl"
      >
        <div class="flex items-start justify-between gap-4">
          <div class="min-w-0">
            <h2 id="bookmark-preview-title" class="text-lg font-semibold">
              Bookmark at {Format.clock(@bookmark.position_seconds)}
            </h2>
            <p class="mt-1 truncate text-sm text-[color:var(--pg-muted)]">{@book.title}</p>
            <p class="mt-1 truncate text-xs font-semibold text-primary">{@chapter_title}</p>
          </div>
          <button
            type="button"
            phx-click="close_bookmark_preview"
            aria-label="Close"
            class="rounded-full p-2 text-base-content/60 transition hover:bg-[color:var(--pg-tab-active)] hover:text-base-content"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <div
          id="bookmark-preview-player"
          phx-hook="BookmarkPreview"
          data-start={@bookmark.position_seconds}
          data-jump-backward={@settings.jump_backward}
          data-jump-forward={@settings.jump_forward}
          class="mt-4 rounded-xl border border-[color:var(--pg-border)] bg-[color:var(--pg-surface-raised)] p-4"
        >
          <p :if={@bookmark.note} class="mb-3 text-sm">{@bookmark.note}</p>
          <audio
            class="hidden"
            preload="metadata"
            src={bookmark_preview_src(@book, @token)}
          ></audio>

          <div class="flex items-center justify-center gap-3">
            <button
              type="button"
              data-preview-action="back"
              class="flex size-10 items-center justify-center rounded-full text-base-content/70 transition hover:bg-[color:var(--pg-tab-active)] hover:text-base-content"
              aria-label={"Jump preview backward #{@settings.jump_backward} seconds"}
            >
              <.preview_skip_icon seconds={@settings.jump_backward} direction={:back} />
            </button>
            <button
              type="button"
              data-preview-action="toggle"
              data-preview-play
              class="flex size-12 items-center justify-center rounded-full bg-primary text-primary-content shadow transition hover:opacity-90"
              aria-label="Play preview"
            >
              <span data-preview-play-icon class="hero-play-solid size-6" />
            </button>
            <button
              type="button"
              data-preview-action="forward"
              class="flex size-10 items-center justify-center rounded-full text-base-content/70 transition hover:bg-[color:var(--pg-tab-active)] hover:text-base-content"
              aria-label={"Jump preview forward #{@settings.jump_forward} seconds"}
            >
              <.preview_skip_icon seconds={@settings.jump_forward} direction={:forward} />
            </button>
          </div>

          <div class="mt-4 h-2 overflow-hidden rounded-full bg-[color:var(--pg-tab)]">
            <div data-preview-progress class="h-full w-0 rounded-full bg-primary transition-[width]">
            </div>
          </div>

          <div class="mt-2 flex items-center justify-between text-xs text-[color:var(--pg-muted)]">
            <span data-preview-time>{Format.clock(@bookmark.position_seconds)}</span>
            <span>Preview only</span>
          </div>

          <button
            type="button"
            phx-click="play_selected_bookmark"
            class="mt-4 w-full rounded-xl bg-primary px-4 py-2.5 text-sm font-semibold text-primary-content transition hover:opacity-90"
          >
            Play from here
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp bookmark_preview_src(book, token) do
    "/books/#{book.id}/audio?token=#{URI.encode_www_form(token)}"
  end

  defp chapter_duration(%{start_seconds: start, end_seconds: finish})
       when is_number(start) and is_number(finish) do
    max(finish - start, 0.0)
  end

  defp chapter_duration(_chapter), do: 0.0

  attr :seconds, :integer, required: true
  attr :direction, :atom, values: [:back, :forward], required: true

  defp preview_skip_icon(assigns) do
    ~H"""
    <span class="relative inline-flex size-7 items-center justify-center">
      <svg
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.6"
        stroke-linecap="round"
        stroke-linejoin="round"
        class={["size-7", @direction == :back && "-scale-x-100"]}
        aria-hidden="true"
      >
        <path d="M12 4 a 8 8 0 1 0 5.66 2.34" />
        <polyline points="9 1.5 12 4 9.5 7" />
      </svg>
      <span class="absolute text-[8px] font-semibold leading-none tabular-nums">
        {@seconds}
      </span>
    </span>
    """
  end

  attr :form, :map, required: true
  attr :book, :map, required: true
  attr :tab, :string, required: true
  attr :uploads, :map, required: true
  attr :cover_url, :string, required: true
  attr :chapters, :list, required: true
  attr :show_chapter_lookup, :boolean, required: true
  attr :chapter_lookup_form, :map, required: true
  attr :chapter_lookup_loading?, :boolean, required: true
  attr :chapter_lookup_result, :any, required: true
  attr :chapter_lookup_error, :string, default: nil
  attr :all_series, :list, required: true
  attr :all_collections, :list, required: true
  attr :all_narrators, :list, required: true
  attr :all_publishers, :list, required: true
  attr :selected_series, :list, required: true
  attr :selected_collections, :list, required: true
  attr :selected_narrators, :list, required: true
  attr :series_query, :string, required: true
  attr :collections_query, :string, required: true
  attr :narrators_query, :string, required: true
  attr :series_error, :string, default: nil
  attr :playlists, :list, required: true
  attr :book_playlist_ids, :any, required: true

  defp edit_modal(assigns) do
    ~H"""
    <div
      id="book-edit-modal"
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      phx-window-keydown="close_edit"
      phx-key="escape"
    >
      <div class="absolute inset-0 bg-black/50" phx-click="close_edit" aria-hidden="true"></div>

      <div
        id="book-edit-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="book-edit-title"
        class="relative flex h-[85vh] w-full max-w-2xl flex-col overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-2xl"
      >
        <div class="flex items-center justify-between border-b border-base-300 px-6 py-4">
          <h2 id="book-edit-title" class="text-lg font-semibold">Edit Book</h2>
          <button
            type="button"
            phx-click="close_edit"
            aria-label="Close"
            class="flex size-8 items-center justify-center rounded-full text-base-content/60 hover:bg-base-200 hover:text-base-content transition"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <div class="flex gap-1 border-b border-base-300 px-4">
          <.edit_tab_button tab="details" active={@tab} icon="hero-list-bullet">Details</.edit_tab_button>
          <.edit_tab_button tab="cover" active={@tab} icon="hero-photo">Cover</.edit_tab_button>
          <.edit_tab_button tab="chapters" active={@tab} icon="hero-queue-list">
            Chapters
          </.edit_tab_button>
        </div>

        <div
          id="book-edit-tab-content"
          class={[
            "min-h-0 flex-1",
            if(@tab == "chapters", do: "overflow-hidden", else: "overflow-y-auto")
          ]}
        >
          <%= cond do %>
            <% @tab == "cover" -> %>
              <.cover_tab book={@book} uploads={@uploads} cover_url={@cover_url} />
            <% @tab == "chapters" -> %>
              <.chapters_tab chapters={@chapters} />
            <% true -> %>
              <.form
                for={@form}
                id="book-edit-form"
                phx-change="validate_edit"
                phx-submit="save_edit"
              >
                <div class="space-y-4 px-6 py-5">
                  <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                    <.input field={@form[:title]} type="text" label="Title" />
                    <.input field={@form[:subtitle]} type="text" label="Subtitle" />
                  </div>

                  <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                    <.input
                      name="book[authors]"
                      value={Enum.map_join(@book.authors, ", ", & &1.name)}
                      type="text"
                      label="Authors"
                      placeholder="Comma-separated"
                    />
                    <.input field={@form[:published_date]} type="date" label="Publish date" />
                  </div>

                  <.input
                    name="book[genres]"
                    value={Enum.map_join(@book.genres, ", ", & &1.name)}
                    type="text"
                    label="Genres"
                    placeholder="Comma-separated"
                  />

                  <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                    <.tag_input
                      field="series"
                      label="Series"
                      add_event="tag_add_series"
                      remove_event="tag_remove_series"
                      suggestion_event="tag_prefill_series"
                      pills={Enum.map(@selected_series, &series_pill/1)}
                      query={@series_query}
                      error={@series_error}
                      suggestions={
                        tag_suggestions(
                          @all_series,
                          Enum.map(@selected_series, & &1.name),
                          @series_query
                        )
                      }
                      show_create={
                        new_tag?(@all_series, Enum.map(@selected_series, & &1.name), @series_query) and
                          valid_series_entry?(@series_query)
                      }
                      placeholder={~s(Name plus number, e.g. "Uma Aventura #1")}
                    />
                    <.tag_input
                      field="collections"
                      label="Collections"
                      add_event="tag_add_collection"
                      remove_event="tag_remove_collection"
                      pills={@selected_collections}
                      query={@collections_query}
                      suggestions={
                        tag_suggestions(@all_collections, @selected_collections, @collections_query)
                      }
                      show_create={
                        new_tag?(@all_collections, @selected_collections, @collections_query)
                      }
                      placeholder="Type to search collections"
                    />
                  </div>

                  <.input field={@form[:description]} type="textarea" label="Description" rows="6" />

                  <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                    <.tag_input
                      field="narrators"
                      label="Narrators"
                      add_event="tag_add_narrator"
                      remove_event="tag_remove_narrator"
                      pills={@selected_narrators}
                      query={@narrators_query}
                      suggestions={
                        tag_suggestions(@all_narrators, @selected_narrators, @narrators_query)
                      }
                      show_create={new_tag?(@all_narrators, @selected_narrators, @narrators_query)}
                      placeholder="Type a narrator name"
                    />
                    <div>
                      <.input
                        field={@form[:publisher_name]}
                        type="text"
                        label="Publisher"
                        placeholder="Type or choose a publisher"
                        list="publisher-options"
                      />
                      <datalist id="publisher-options">
                        <option :for={publisher <- @all_publishers} value={publisher} />
                      </datalist>
                    </div>
                  </div>

                  <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
                    <.input field={@form[:language]} type="text" label="Language" />
                    <.input field={@form[:isbn]} type="text" label="ISBN" />
                    <.input field={@form[:asin]} type="text" label="ASIN" />
                  </div>
                </div>

                <div class="flex items-center justify-end gap-3 border-t border-base-300 px-6 py-4">
                  <button
                    type="button"
                    phx-click="close_edit"
                    class="rounded-lg border border-base-300 px-4 py-2 text-sm font-medium hover:bg-base-200 transition"
                  >
                    Cancel
                  </button>
                  <button
                    type="submit"
                    class="rounded-lg bg-primary px-4 py-2 text-sm font-semibold text-primary-content hover:opacity-90 transition"
                  >
                    Save
                  </button>
                </div>
              </.form>

              <.playlist_control playlists={@playlists} book_playlist_ids={@book_playlist_ids} />
          <% end %>
        </div>
      </div>

      <.chapter_lookup_modal
        :if={@show_chapter_lookup}
        form={@chapter_lookup_form}
        loading?={@chapter_lookup_loading?}
        result={@chapter_lookup_result}
        error={@chapter_lookup_error}
        current_chapter_count={length(@chapters)}
        book_duration={@book.duration_seconds || 0.0}
      />
    </div>
    """
  end

  attr :playlists, :list, required: true
  attr :book_playlist_ids, :any, required: true

  defp playlist_control(assigns) do
    ~H"""
    <div class="border-t border-base-300 px-6 py-5">
      <h3 class="text-sm font-medium mb-2">Playlists</h3>

      <div
        :if={member_playlists(@playlists, @book_playlist_ids) != []}
        class="mb-3 flex flex-wrap gap-1.5"
      >
        <span
          :for={pl <- member_playlists(@playlists, @book_playlist_ids)}
          class="inline-flex items-center gap-1 rounded-full bg-primary/10 px-2 py-0.5 text-xs font-medium text-primary"
        >
          {pl.name}
          <button
            type="button"
            phx-click="remove_from_playlist"
            phx-value-playlist_id={pl.id}
            aria-label={"Remove from #{pl.name}"}
            class="rounded-full hover:bg-primary/20"
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </span>
      </div>

      <div class="flex flex-wrap items-center gap-2">
        <form phx-change="add_to_playlist" id="add-to-playlist-form" class="flex items-center gap-2">
          <select
            name="playlist_id"
            class="rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm focus:border-primary focus:outline-none"
          >
            <option value="">Add to playlist…</option>
            <option :for={pl <- non_member_playlists(@playlists, @book_playlist_ids)} value={pl.id}>
              {pl.name}
            </option>
          </select>
        </form>

        <form
          phx-submit="create_playlist_with_book"
          class="flex items-center gap-2"
          id="create-playlist-form"
        >
          <input
            type="text"
            name="name"
            placeholder="…or new playlist"
            class="rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm focus:border-primary focus:outline-none"
          />
          <button
            type="submit"
            class="inline-flex items-center gap-1 rounded-lg border border-base-300 px-3 py-2 text-sm font-medium hover:bg-base-200"
          >
            <.icon name="hero-plus" class="size-4" /> Create
          </button>
        </form>
      </div>
    </div>
    """
  end

  defp member_playlists(playlists, ids),
    do: Enum.filter(playlists, &MapSet.member?(ids, &1.id))

  defp non_member_playlists(playlists, ids),
    do: Enum.reject(playlists, &MapSet.member?(ids, &1.id))

  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :add_event, :string, required: true
  attr :remove_event, :string, required: true
  attr :suggestion_event, :string, default: nil
  attr :pills, :list, required: true
  attr :query, :string, required: true
  attr :suggestions, :list, required: true
  attr :show_create, :boolean, required: true
  attr :placeholder, :string, default: ""
  attr :error, :string, default: nil

  defp tag_input(assigns) do
    ~H"""
    <div class="relative" id={"tag-input-#{@field}"}>
      <label class="block text-sm font-medium mb-1">{@label}</label>

      <div class={[
        "flex flex-wrap items-center gap-1.5 rounded-lg border bg-base-100 p-2 focus-within:border-primary",
        if(@error, do: "border-error", else: "border-base-300")
      ]}>
        <span
          :for={pill <- @pills}
          class="inline-flex items-center gap-1 rounded-full bg-primary/10 px-2 py-0.5 text-xs font-medium text-primary"
        >
          {pill}
          <button
            type="button"
            phx-click={@remove_event}
            phx-value-name={pill_name(pill)}
            aria-label={"Remove #{pill}"}
            class="rounded-full hover:bg-primary/20"
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </span>

        <input
          type="text"
          name={"book[pending_#{@field}]"}
          autocomplete="off"
          placeholder={@placeholder}
          phx-hook=".TagInput"
          phx-update="ignore"
          data-field={@field}
          data-filter-event="tag_filter"
          data-add-event={@add_event}
          id={"tag-field-#{@field}"}
          class="min-w-[8rem] flex-1 border-0 bg-transparent p-0.5 text-sm focus:outline-none focus:ring-0"
        />
        <script :type={Phoenix.LiveView.ColocatedHook} name=".TagInput">
          export default {
            mounted() {
              const field = this.el.dataset.field
              const filterEvent = this.el.dataset.filterEvent
              const addEvent = this.el.dataset.addEvent
              let timer = null

              this.el.addEventListener("input", () => {
                clearTimeout(timer)
                timer = setTimeout(() => {
                  this.pushEvent(filterEvent, {field: field, value: this.el.value})
                }, 120)
              })

              this.el.addEventListener("keydown", (e) => {
                if (e.key === "Enter") {
                  // Don't submit the surrounding edit form; add the typed tag.
                  e.preventDefault()
                  const value = this.el.value.trim()
                  if (value !== "") this.pushEvent(addEvent, {name: value})
                }
              })

              // The server clears the query after a tag is added; reflect that.
              this.handleEvent("tag_input_cleared", ({field: cleared}) => {
                if (cleared === field) this.el.value = ""
              })

              // The server can prefill the input (e.g. "Series #") and focus it
              // so the user can type the sequence.
              this.handleEvent("tag_input_set", ({field: target, value}) => {
                if (target === field) {
                  this.el.value = value
                  this.el.focus()
                }
              })
            }
          }
        </script>
      </div>

      <ul
        :if={@suggestions != [] or @show_create}
        class="absolute z-20 mt-1 max-h-52 w-full overflow-auto rounded-lg border border-base-300 bg-base-100 py-1 shadow-lg"
      >
        <li :for={name <- @suggestions}>
          <button
            type="button"
            phx-click={@suggestion_event || @add_event}
            phx-value-name={name}
            class="flex w-full items-center px-3 py-1.5 text-left text-sm hover:bg-base-200"
          >
            {name}
          </button>
        </li>
        <li :if={@show_create}>
          <button
            type="button"
            phx-click={@add_event}
            phx-value-name={String.trim(@query)}
            class="flex w-full items-center gap-1 px-3 py-1.5 text-left text-sm text-primary hover:bg-base-200"
          >
            <.icon name="hero-plus" class="size-4" /> Create "{String.trim(@query)}"
          </button>
        </li>
      </ul>

      <p :if={@error} class="mt-1 text-xs text-error">{@error}</p>
    </div>
    """
  end

  # A collection pill is just its name; a series pill may be "Name #3" — the
  # remove event keys off the base name.
  defp pill_name(pill) do
    case String.split(pill, " #", parts: 2) do
      [name, _seq] -> name
      [name] -> name
    end
  end

  attr :tab, :string, required: true
  attr :active, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp edit_tab_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="edit_tab"
      phx-value-tab={@tab}
      class={[
        "flex items-center gap-2 border-b-2 px-4 py-3 text-sm font-medium transition -mb-px",
        if(@active == @tab,
          do: "border-primary text-primary",
          else: "border-transparent text-base-content/60 hover:text-base-content"
        )
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :book, :map, required: true
  attr :uploads, :map, required: true
  attr :cover_url, :string, required: true

  defp cover_tab(assigns) do
    ~H"""
    <div class="space-y-6 px-6 py-5">
      <div class="flex flex-col gap-6 sm:flex-row">
        <div class="shrink-0">
          <div class="aspect-square w-40 overflow-hidden rounded-lg bg-base-300">
            <img
              src={cover_url(@book)}
              alt={@book.title}
              class="size-full object-cover"
              onerror="this.style.visibility='hidden'"
            />
          </div>
          <p class="mt-1 text-center text-xs text-base-content/50">Current cover</p>
        </div>

        <div class="min-w-0 flex-1 space-y-6">
          <div>
            <h3 class="mb-2 text-sm font-medium">Upload from your device</h3>
            <form id="cover-upload-form" phx-change="validate_cover" phx-submit="upload_cover">
              <label
                for={@uploads.cover.ref}
                phx-drop-target={@uploads.cover.ref}
                class="flex cursor-pointer flex-col items-center justify-center gap-2 rounded-xl border-2 border-dashed border-base-300 bg-base-200/40 px-4 py-8 text-center transition hover:border-primary hover:bg-base-200"
              >
                <.icon name="hero-arrow-up-tray" class="size-6 text-base-content/50" />
                <%= if @uploads.cover.entries == [] do %>
                  <span class="text-sm font-medium">
                    Click to choose an image
                    <span class="text-base-content/50">or drag &amp; drop</span>
                  </span>
                  <span class="text-xs text-base-content/40">JPG, PNG or WEBP up to 15&nbsp;MB</span>
                <% else %>
                  <span :for={entry <- @uploads.cover.entries} class="text-sm font-medium">
                    {entry.client_name}
                  </span>
                <% end %>
              </label>

              <.live_file_input upload={@uploads.cover} class="sr-only" />

              <div :for={entry <- @uploads.cover.entries} class="mt-1">
                <div
                  :for={err <- upload_errors(@uploads.cover, entry)}
                  class="text-xs text-error"
                >
                  {upload_error_to_string(err)}
                </div>
              </div>

              <button
                type="submit"
                disabled={@uploads.cover.entries == []}
                class="mt-3 rounded-lg bg-primary px-4 py-2 text-sm font-semibold text-primary-content hover:opacity-90 transition disabled:opacity-50"
              >
                Upload cover
              </button>
            </form>
          </div>

          <div>
            <h3 class="mb-2 text-sm font-medium">Or use an image URL</h3>
            <form
              id="cover-url-form"
              phx-change="validate_cover"
              phx-submit="submit_cover_url"
              class="flex gap-2"
            >
              <input
                type="url"
                name="cover_url"
                value={@cover_url}
                placeholder="https://example.com/cover.jpg"
                class="min-w-0 flex-1 rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm focus:border-primary focus:outline-none"
              />
              <button
                type="submit"
                disabled={not valid_cover_url?(@cover_url)}
                class="shrink-0 rounded-lg bg-primary px-4 py-2 text-sm font-semibold text-primary-content hover:opacity-90 transition disabled:opacity-50 disabled:cursor-not-allowed"
              >
                Submit
              </button>
            </form>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :chapters, :list, required: true

  defp chapters_tab(assigns) do
    ~H"""
    <div id="chapter-edit-layout" class="flex h-full min-h-0 flex-col">
      <div class="flex shrink-0 items-center justify-between gap-3 border-b border-base-300 px-6 py-3">
        <div class="text-sm text-base-content/60">
          {Format.count(length(@chapters), "chapter")}
        </div>
        <div class="flex items-center gap-2">
          <button
            type="button"
            phx-click="open_chapter_lookup"
            class="inline-flex items-center gap-1 rounded-lg border border-base-300 px-3 py-1.5 text-sm font-medium hover:bg-base-200 transition"
          >
            <.icon name="hero-magnifying-glass" class="size-4" /> Lookup
          </button>
          <button
            type="button"
            phx-click="add_chapter"
            class="inline-flex items-center gap-1 rounded-lg border border-base-300 px-3 py-1.5 text-sm font-medium hover:bg-base-200 transition"
          >
            <.icon name="hero-plus" class="size-4" /> Add
          </button>
          <button
            :if={@chapters != []}
            type="button"
            phx-click="remove_all_chapters"
            data-confirm="Remove all chapters?"
            class="inline-flex items-center gap-1 rounded-lg border border-base-300 px-3 py-1.5 text-sm font-medium hover:bg-base-200 transition"
          >
            <.icon name="hero-trash" class="size-4" /> Remove all
          </button>
        </div>
      </div>

      <div id="chapter-edit-list" class="min-h-0 flex-1 overflow-y-auto px-6 py-4">
        <div
          :if={@chapters == []}
          class="rounded-xl border border-dashed border-base-300 p-8 text-center text-sm text-base-content/50"
        >
          No chapters. Add one to get started.
        </div>

        <div class="space-y-2">
          <div
            :for={{chapter, index} <- Enum.with_index(@chapters)}
            id={"chapter-edit-#{chapter.id}"}
            class="flex items-center gap-2"
          >
            <span class="w-8 shrink-0 text-right text-xs tabular-nums text-base-content/40">
              #{index + 1}
            </span>
            <input
              type="text"
              value={chapter.start}
              phx-blur="update_chapter_field"
              phx-value-id={chapter.id}
              phx-value-field="start"
              aria-label="Start time"
              placeholder="HH:MM:SS"
              class="w-28 shrink-0 rounded-lg border border-base-300 bg-base-100 px-2 py-1.5 text-sm tabular-nums focus:border-primary focus:outline-none"
            />
            <input
              type="text"
              value={chapter.title}
              phx-blur="update_chapter_field"
              phx-value-id={chapter.id}
              phx-value-field="title"
              aria-label="Chapter title"
              placeholder="Chapter title"
              class="min-w-0 flex-1 rounded-lg border border-base-300 bg-base-100 px-3 py-1.5 text-sm focus:border-primary focus:outline-none"
            />
            <button
              type="button"
              phx-click="play_chapter_edit"
              phx-value-id={chapter.id}
              title="Play from this timestamp"
              aria-label="Play from this timestamp"
              class="flex size-8 shrink-0 items-center justify-center rounded-lg text-base-content/50 hover:bg-base-200 hover:text-primary transition"
            >
              <.icon name="hero-play" class="size-4" />
            </button>
            <button
              type="button"
              phx-click="insert_chapter_below"
              phx-value-id={chapter.id}
              title="Insert chapter below"
              aria-label="Insert chapter below"
              class="flex size-8 shrink-0 items-center justify-center rounded-lg text-base-content/50 hover:bg-base-200 hover:text-base-content transition"
            >
              <.icon name="hero-plus-circle" class="size-4" />
            </button>
            <button
              type="button"
              phx-click="remove_chapter"
              phx-value-id={chapter.id}
              aria-label="Remove chapter"
              class="flex size-8 shrink-0 items-center justify-center rounded-lg text-base-content/50 hover:bg-base-200 hover:text-error transition"
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </div>
        </div>
      </div>

      <div
        id="chapter-edit-actions"
        class="flex shrink-0 items-center justify-end gap-3 border-t border-base-300 px-6 py-4"
      >
        <button
          type="button"
          phx-click="close_edit"
          class="rounded-lg border border-base-300 px-4 py-2 text-sm font-medium hover:bg-base-200 transition"
        >
          Cancel
        </button>
        <button
          type="button"
          phx-click="save_chapters"
          class="rounded-lg bg-primary px-4 py-2 text-sm font-semibold text-primary-content hover:opacity-90 transition"
        >
          Save chapters
        </button>
      </div>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :loading?, :boolean, required: true
  attr :result, :any, required: true
  attr :error, :string, default: nil
  attr :current_chapter_count, :integer, required: true
  attr :book_duration, :float, required: true

  defp chapter_lookup_modal(assigns) do
    ~H"""
    <div
      id="audible-chapter-lookup-modal"
      class="fixed inset-0 z-[60] flex items-center justify-center p-4"
    >
      <div
        class="absolute inset-0 bg-black/65 backdrop-blur-sm"
        phx-click="close_chapter_lookup"
        aria-hidden="true"
      >
      </div>

      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="audible-chapter-lookup-title"
        class="relative flex max-h-[80vh] w-full max-w-2xl flex-col overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-2xl"
      >
        <div class="flex shrink-0 items-center justify-between border-b border-base-300 px-6 py-4">
          <div>
            <h3 id="audible-chapter-lookup-title" class="text-lg font-semibold">
              Find Audible chapters
            </h3>
            <p class="mt-0.5 text-xs text-base-content/50">Chapter data provided by Audnexus</p>
          </div>
          <button
            type="button"
            phx-click="close_chapter_lookup"
            aria-label="Close chapter lookup"
            class="flex size-8 items-center justify-center rounded-full text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <%= if @result do %>
          <div class="min-h-0 flex-1 overflow-y-auto px-6 py-5">
            <div class="grid gap-3 sm:grid-cols-2">
              <div class="rounded-xl border border-base-300 bg-base-200/40 p-4">
                <div class="text-xs font-medium uppercase tracking-wide text-base-content/50">
                  Audible result
                </div>
                <div class="mt-2 flex items-end justify-between gap-4">
                  <span class="text-2xl font-semibold tabular-nums">
                    {Format.clock(@result.runtime_length_seconds)}
                  </span>
                  <span class="text-sm text-base-content/60">
                    {Format.count(length(@result.chapters), "chapter")}
                  </span>
                </div>
              </div>
              <div class="rounded-xl border border-base-300 bg-base-200/40 p-4">
                <div class="text-xs font-medium uppercase tracking-wide text-base-content/50">
                  Your audiobook
                </div>
                <div class="mt-2 flex items-end justify-between gap-4">
                  <span class="text-2xl font-semibold tabular-nums">
                    {Format.clock(@book_duration)}
                  </span>
                  <span class="text-sm text-base-content/60">
                    {Format.count(@current_chapter_count, "chapter")}
                  </span>
                </div>
              </div>
            </div>

            <div
              :if={chapter_duration_mismatch?(@result, @book_duration)}
              id="audible-duration-warning"
              class="mt-4 flex gap-3 rounded-xl border border-warning/40 bg-warning/10 px-4 py-3 text-sm"
            >
              <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0 text-warning" />
              <p>
                The Audible runtime differs from this audiobook. Review the timestamps before saving;
                chapters starting after the local duration will not be imported.
              </p>
            </div>

            <div class="mt-5 overflow-hidden rounded-xl border border-base-300">
              <div class="grid grid-cols-[7rem_minmax(0,1fr)] border-b border-base-300 bg-base-200/60 px-4 py-2 text-xs font-semibold uppercase tracking-wide text-base-content/50">
                <span>Start</span>
                <span>Title</span>
              </div>
              <div id="audible-chapter-results" class="max-h-72 overflow-y-auto">
                <div
                  :for={{chapter, index} <- Enum.with_index(@result.chapters)}
                  id={"audible-chapter-result-#{index}"}
                  class={[
                    "grid grid-cols-[7rem_minmax(0,1fr)] border-b border-base-300 px-4 py-2.5 text-sm last:border-b-0",
                    index |> rem(2) == 0 && "bg-base-200/25",
                    (@book_duration > 0 and chapter.start_seconds >= @book_duration) &&
                      "bg-error/10 text-error"
                  ]}
                >
                  <span class="tabular-nums">{Format.clock(chapter.start_seconds)}</span>
                  <span class="truncate">{chapter.title}</span>
                </div>
              </div>
            </div>
          </div>

          <div class="flex shrink-0 flex-wrap items-center gap-3 border-t border-base-300 px-6 py-4">
            <button
              type="button"
              phx-click="reset_chapter_lookup"
              class="inline-flex items-center gap-1.5 rounded-lg border border-base-300 px-4 py-2 text-sm font-medium transition hover:bg-base-200"
            >
              <.icon name="hero-arrow-left" class="size-4" /> Back
            </button>
            <div class="flex-1"></div>
            <button
              type="button"
              phx-click="map_audible_chapter_titles"
              disabled={@current_chapter_count == 0}
              title={
                if @current_chapter_count == 0,
                  do: "Add chapters before mapping titles",
                  else: "Keep current timestamps and replace matching titles"
              }
              class="rounded-lg border border-base-300 px-4 py-2 text-sm font-medium transition hover:bg-base-200 disabled:cursor-not-allowed disabled:opacity-40"
            >
              Map titles only
            </button>
            <button
              type="button"
              phx-click="apply_audible_chapters"
              class="rounded-lg bg-primary px-4 py-2 text-sm font-semibold text-primary-content transition hover:opacity-90"
            >
              Use these chapters
            </button>
          </div>
        <% else %>
          <.form
            for={@form}
            id="audible-chapter-lookup-form"
            phx-submit="lookup_audible_chapters"
            class="px-6 py-6"
          >
            <div class="grid items-end gap-4 sm:grid-cols-[minmax(0,1fr)_8rem_auto]">
              <.input
                field={@form[:asin]}
                type="text"
                label="ASIN"
                placeholder="B017V4IM1G"
                autocomplete="off"
              />
              <.input
                field={@form[:region]}
                type="select"
                label="Region"
                options={audible_region_options()}
              />
              <button
                type="submit"
                disabled={@loading?}
                class="mb-2 inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-primary px-5 text-sm font-semibold text-primary-content transition hover:opacity-90 disabled:cursor-wait disabled:opacity-60"
              >
                <.icon :if={@loading?} name="hero-arrow-path" class="size-4 animate-spin" />
                {if @loading?, do: "Searching…", else: "Search"}
              </button>
            </div>

            <div class="mt-3">
              <.input
                field={@form[:remove_branding]}
                type="checkbox"
                label="Remove Audible intro and outro from chapter timing"
              />
            </div>

            <div
              :if={@error}
              id="audible-chapter-lookup-error"
              class="mt-4 flex items-start gap-2 rounded-xl border border-error/30 bg-error/10 px-4 py-3 text-sm text-error"
            >
              <.icon name="hero-exclamation-circle" class="mt-0.5 size-4 shrink-0" />
              <span>{@error}</span>
            </div>

            <p class="mt-5 text-xs leading-relaxed text-base-content/45">
              Use the ASIN from the selected Audible marketplace, not an Amazon product ASIN.
              Lookup changes are staged here and are only persisted when you save the chapter editor.
            </p>
          </.form>
        <% end %>
      </div>
    </div>
    """
  end

  defp audible_region_options do
    [
      {"United States", "us"},
      {"Canada", "ca"},
      {"United Kingdom", "uk"},
      {"Australia", "au"},
      {"France", "fr"},
      {"Germany", "de"},
      {"Japan", "jp"},
      {"Italy", "it"},
      {"India", "in"},
      {"Spain", "es"}
    ]
  end

  defp chapter_duration_mismatch?(_result, duration) when duration <= 0, do: false

  defp chapter_duration_mismatch?(result, duration),
    do: abs(result.runtime_length_seconds - duration) >= 1

  # A URL is considered valid enough to enable Submit when it has an http(s)
  # scheme and a host.
  defp valid_cover_url?(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp valid_cover_url?(_), do: false

  defp upload_error_to_string(:too_large), do: "file is too large"
  defp upload_error_to_string(:not_accepted), do: "unsupported file type"
  defp upload_error_to_string(:too_many_files), do: "too many files"
  defp upload_error_to_string(_), do: "invalid file"
end
