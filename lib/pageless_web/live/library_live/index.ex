defmodule PagelessWeb.LibraryLive.Index do
  use PagelessWeb, :live_view

  alias Pageless.Format
  alias Pageless.Library
  alias Pageless.Library.Events
  alias Pageless.Playback
  alias Pageless.Accounts
  alias Pageless.Accounts.PlayerSettings
  alias PagelessWeb.PlayerLive

  @sorts %{
    "title" => :title,
    "author_first" => :author_first,
    "author_last" => :author_last,
    "published" => :published,
    "added" => :added,
    "size" => :size,
    "duration" => :duration,
    "modified" => :modified,
    "progress_updated" => :progress_updated,
    "progress_started" => :progress_started,
    "progress_finished" => :progress_finished,
    "random" => :random
  }

  @sort_options [
    %{id: "title", label: "Title", icon: "hero-bars-arrow-down"},
    %{id: "author_first", label: "Author (First Last)", icon: "hero-user"},
    %{id: "author_last", label: "Author (Last, First)", icon: "hero-user"},
    %{id: "published", label: "Publish year", icon: "hero-calendar-days"},
    %{id: "added", label: "Added at", icon: "hero-clock"},
    %{id: "size", label: "Size", icon: "hero-circle-stack"},
    %{id: "duration", label: "Duration", icon: "hero-play-circle"},
    %{id: "modified", label: "File modified", icon: "hero-document"},
    %{id: "progress_updated", label: "Progress: Last updated", icon: "hero-arrow-path"},
    %{id: "progress_started", label: "Progress: Started", icon: "hero-play"},
    %{id: "progress_finished", label: "Progress: Finished", icon: "hero-check-circle"},
    %{id: "random", label: "Randomly", icon: "hero-arrows-right-left"}
  ]

  @filter_categories [
    %{id: :authors, label: "Authors", icon: "hero-user"},
    %{id: :narrators, label: "Narrators", icon: "hero-speaker-wave"},
    %{id: :progress, label: "Progress", icon: "hero-chart-bar"},
    %{id: :series, label: "Series", icon: "hero-rectangle-stack"},
    %{id: :collections, label: "Collections", icon: "hero-rectangle-group"},
    %{id: :playlists, label: "Playlists", icon: "hero-queue-list"},
    %{id: :genres, label: "Genres", icon: "hero-tag"},
    %{id: :publishers, label: "Publishers", icon: "hero-building-office"},
    %{id: :languages, label: "Languages", icon: "hero-language"},
    %{id: :libraries, label: "Libraries", icon: "hero-book-open"}
  ]

  @progress_options [
    %{id: "not_started", name: "Not started"},
    %{id: "in_progress", name: "In progress"},
    %{id: "finished", name: "Finished"}
  ]

  @progress_values %{
    "not_started" => :not_started,
    "in_progress" => :in_progress,
    "finished" => :finished
  }

  @search_categories [
    :authors,
    :narrators,
    :series,
    :collections,
    :playlists,
    :genres,
    :publishers,
    :languages,
    :libraries
  ]
  @search_min_length 2
  @search_group_limit 5

  @cover_size_step 20

  @impl true
  def mount(_params, _session, socket) do
    settings = Accounts.get_player_settings(socket.assigns.current_scope.user)
    filter_options = Library.book_filter_options(socket.assigns.current_scope)

    if connected?(socket) do
      Events.subscribe(socket.assigns.current_scope)

      Phoenix.PubSub.subscribe(
        Pageless.PubSub,
        PlayerLive.state_topic(socket.assigns.current_scope.user.id)
      )

      PlayerLive.request_state(socket.assigns.current_scope.user.id)
    end

    {:ok,
     socket
     |> assign(
       page_title: "Library",
       search: "",
       search_open?: false,
       search_results: [],
       sort: "title",
       sort_direction: "asc",
       sort_options: @sort_options,
       sort_open?: false,
       filters: empty_filters(),
       filter_options: Map.put(filter_options, :progress, @progress_options),
       filter_categories: @filter_categories,
       active_filter: :authors,
       filter_search: "",
       filters_open?: false,
       active_filter_count: 0,
       selected_filters: [],
       book_count: 0,
       cover_size: settings.cover_size,
       cover_size_min: PlayerSettings.cover_size_min(),
       cover_size_max: PlayerSettings.cover_size_max(),
       cover_size_control_raised?: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    search = if is_binary(params["search"]), do: params["search"], else: ""
    sort = if Map.has_key?(@sorts, params["sort"]), do: params["sort"], else: "title"
    sort_direction = parse_sort_direction(params["direction"], sort)
    filters = filters_from_params(params, socket.assigns.filter_options)

    {:noreply,
     socket
     |> assign(
       search: search,
       sort: sort,
       sort_direction: sort_direction,
       filters: filters,
       active_filter_count: filter_count(filters),
       selected_filters: selected_filters(filters, socket.assigns.filter_options)
     )
     |> load_books()}
  end

  @impl true
  def handle_info({:player_state, state}, socket) do
    {:noreply, assign(socket, cover_size_control_raised?: not is_nil(Map.get(state, :book_id)))}
  end

  def handle_info({:catalog_changed, _changes}, socket) do
    filter_options =
      socket.assigns.current_scope
      |> Library.book_filter_options()
      |> Map.put(:progress, @progress_options)

    filters = filters_from_params(stringify_filters(socket.assigns.filters), filter_options)

    {:noreply,
     socket
     |> assign(
       filter_options: filter_options,
       filters: filters,
       active_filter_count: filter_count(filters),
       selected_filters: selected_filters(filters, filter_options)
     )
     |> load_books()}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply,
     socket
     |> assign(search_open?: search_ready?(search))
     |> patch_library([search: search], replace: true)}
  end

  def handle_event("open_search", _params, socket) do
    {:noreply, assign(socket, search_open?: search_ready?(socket.assigns.search))}
  end

  def handle_event("close_search", _params, socket) do
    {:noreply, assign(socket, search_open?: false)}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply,
     socket |> assign(search_open?: false) |> patch_library([search: ""], replace: true)}
  end

  def handle_event("open_sort", _params, socket) do
    {:noreply, assign(socket, sort_open?: true, filters_open?: false)}
  end

  def handle_event("close_sort", _params, socket) do
    {:noreply, assign(socket, sort_open?: false)}
  end

  def handle_event("select_sort", %{"sort" => sort}, socket) when is_map_key(@sorts, sort) do
    cond do
      sort == "random" and socket.assigns.sort == "random" ->
        {:noreply, socket |> assign(sort_open?: false) |> load_books()}

      true ->
        direction =
          if sort == socket.assigns.sort,
            do: opposite_direction(socket.assigns.sort_direction),
            else: default_sort_direction(sort)

        {:noreply,
         socket
         |> assign(sort_open?: false)
         |> patch_library(sort: sort, sort_direction: direction)}
    end
  end

  def handle_event("select_sort", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_sort_direction", _params, socket) do
    if socket.assigns.sort == "random" do
      {:noreply, socket}
    else
      {:noreply,
       patch_library(socket,
         sort_direction: opposite_direction(socket.assigns.sort_direction)
       )}
    end
  end

  def handle_event("open_filters", _params, socket) do
    {:noreply, assign(socket, filters_open?: true, sort_open?: false)}
  end

  def handle_event("close_filters", _params, socket) do
    {:noreply, assign(socket, filters_open?: false, filter_search: "")}
  end

  def handle_event("select_filter_category", %{"category" => category}, socket) do
    case filter_category(category) do
      nil -> {:noreply, socket}
      category -> {:noreply, assign(socket, active_filter: category, filter_search: "")}
    end
  end

  def handle_event("filter_options", %{"filter_search" => search}, socket) do
    {:noreply, assign(socket, filter_search: search)}
  end

  def handle_event("toggle_filter", %{"category" => category, "id" => value}, socket) do
    with category when not is_nil(category) <- filter_category(category),
         true <- valid_filter_value?(category, value, socket.assigns.filter_options) do
      values = Map.fetch!(socket.assigns.filters, category)
      values = if value in values, do: List.delete(values, value), else: values ++ [value]
      filters = Map.put(socket.assigns.filters, category, values)
      {:noreply, patch_library(socket, filters: filters)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("clear_filter", %{"category" => category}, socket) do
    case filter_category(category) do
      nil ->
        {:noreply, socket}

      category ->
        {:noreply, patch_library(socket, filters: Map.put(socket.assigns.filters, category, []))}
    end
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, patch_library(socket, filters: empty_filters())}
  end

  def handle_event("cover_size_down", _params, socket) do
    size = max(socket.assigns.cover_size - @cover_size_step, PlayerSettings.cover_size_min())
    {:noreply, persist_cover_size(socket, size)}
  end

  def handle_event("cover_size_up", _params, socket) do
    size = min(socket.assigns.cover_size + @cover_size_step, PlayerSettings.cover_size_max())
    {:noreply, persist_cover_size(socket, size)}
  end

  defp persist_cover_size(socket, size) do
    user = socket.assigns.current_scope.user

    case Accounts.update_player_settings(user, %{"cover_size" => size}) do
      {:ok, updated_user} ->
        assign(socket,
          cover_size: size,
          current_scope: %{socket.assigns.current_scope | user: updated_user}
        )

      {:error, _changeset} ->
        socket
    end
  end

  defp load_books(socket) do
    sort = Map.get(@sorts, socket.assigns.sort, :title)
    filters = socket.assigns.filters

    books =
      Library.list_books(socket.assigns.current_scope,
        search: socket.assigns.search,
        sort: sort,
        sort_direction: String.to_existing_atom(socket.assigns.sort_direction),
        author_ids: filters.authors,
        narrator_ids: filters.narrators,
        publisher_ids: filters.publishers,
        genre_ids: filters.genres,
        series_ids: filters.series,
        collection_ids: filters.collections,
        playlist_ids: filters.playlists,
        languages: filters.languages,
        library_ids: filters.libraries,
        progress: Enum.map(filters.progress, &Map.fetch!(@progress_values, &1))
      )

    progress = Playback.progress_by_book(socket.assigns.current_scope)

    decorated = Enum.map(books, &decorate(&1, progress))

    search_results =
      build_search_results(socket.assigns.search, books, socket.assigns.filter_options)

    socket
    |> assign(book_count: length(decorated), search_results: search_results)
    |> stream(:books, decorated, reset: true)
  end

  defp decorate(book, progress_map) do
    progress = Map.get(progress_map, book.id)

    pct =
      case progress do
        %{current_seconds: c, duration_seconds: d} when is_number(d) and d > 0 ->
          min(round(c / d * 100), 100)

        _ ->
          0
      end

    %{
      id: book.id,
      title: book.title,
      authors: Enum.map_join(book.authors, ", ", & &1.name),
      cover_version: book.updated_at,
      duration: book.duration_seconds,
      progress_pct: pct,
      finished: Playback.finished?(progress)
    }
  end

  defp patch_library(socket, changes, opts \\ []) do
    search = Keyword.get(changes, :search, socket.assigns.search)
    sort = Keyword.get(changes, :sort, socket.assigns.sort)
    sort_direction = Keyword.get(changes, :sort_direction, socket.assigns.sort_direction)
    filters = Keyword.get(changes, :filters, socket.assigns.filters)

    params =
      %{}
      |> maybe_put_param("search", search, search != "")
      |> maybe_put_param("sort", sort, sort != "title")
      |> maybe_put_param(
        "direction",
        sort_direction,
        sort_direction != default_sort_direction(sort)
      )
      |> put_filter_params(filters)

    push_patch(socket, to: ~p"/library?#{params}", replace: opts[:replace] || false)
  end

  defp put_filter_params(params, filters) do
    Enum.reduce(filters, params, fn {category, values}, params ->
      maybe_put_param(params, Atom.to_string(category), values, values != [])
    end)
  end

  defp maybe_put_param(params, key, value, true), do: Map.put(params, key, value)
  defp maybe_put_param(params, _key, _value, false), do: params

  defp filters_from_params(params, options) do
    Enum.reduce(Map.keys(empty_filters()), empty_filters(), fn category, filters ->
      values = params |> Map.get(Atom.to_string(category), []) |> List.wrap()
      valid_values = options |> Map.fetch!(category) |> MapSet.new(&to_string(&1.id))

      values = values |> Enum.filter(&MapSet.member?(valid_values, &1)) |> Enum.uniq()
      Map.put(filters, category, values)
    end)
  end

  defp stringify_filters(filters) do
    Map.new(filters, fn {category, values} -> {Atom.to_string(category), values} end)
  end

  defp empty_filters do
    %{
      authors: [],
      narrators: [],
      publishers: [],
      genres: [],
      series: [],
      collections: [],
      playlists: [],
      languages: [],
      libraries: [],
      progress: []
    }
  end

  defp filter_category(category) do
    Enum.find_value(@filter_categories, fn item ->
      if Atom.to_string(item.id) == category, do: item.id
    end)
  end

  defp valid_filter_value?(category, value, options) do
    Enum.any?(Map.fetch!(options, category), &(to_string(&1.id) == value))
  end

  defp filter_count(filters) do
    filters |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
  end

  defp selected_filters(filters, options) do
    for category <- Map.keys(filters),
        option <- Map.fetch!(options, category),
        to_string(option.id) in Map.fetch!(filters, category) do
      %{category: category, value: to_string(option.id), label: option.name}
    end
  end

  defp visible_filter_options(options, category, search) do
    term = search |> String.trim() |> String.downcase()

    options
    |> Map.fetch!(category)
    |> Enum.filter(&(term == "" or String.contains?(String.downcase(&1.name), term)))
  end

  defp category_label(category) do
    @filter_categories |> Enum.find(&(&1.id == category)) |> Map.fetch!(:label)
  end

  defp search_ready?(search), do: String.length(String.trim(search)) >= @search_min_length

  defp build_search_results(search, books, filter_options) do
    if search_ready?(search) do
      term = search |> String.trim() |> String.downcase()

      book_group = %{
        id: :books,
        label: "Books",
        icon: "hero-book-open",
        total: length(books),
        items:
          books
          |> Enum.take(@search_group_limit)
          |> Enum.map(fn book ->
            %{id: book.id, name: book.title, detail: Enum.map_join(book.authors, ", ", & &1.name)}
          end)
      }

      facet_groups =
        Enum.map(@search_categories, fn category ->
          metadata = Enum.find(@filter_categories, &(&1.id == category))

          items =
            filter_options
            |> Map.fetch!(category)
            |> Enum.filter(&String.contains?(String.downcase(&1.name), term))
            |> Enum.take(@search_group_limit)

          %{
            id: category,
            label: metadata.label,
            icon: metadata.icon,
            total: length(items),
            items: items
          }
        end)

      [book_group | facet_groups]
      |> Enum.reject(&(&1.items == []))
    else
      []
    end
  end

  defp search_filter_path(category, id, sort, direction) do
    params =
      %{Atom.to_string(category) => [id]}
      |> maybe_put_param("sort", sort, sort != "title")
      |> maybe_put_param("direction", direction, direction != default_sort_direction(sort))

    ~p"/library?#{params}"
  end

  defp filter_option_dom_id(category, value) do
    "filter-option-#{category}-#{filter_value_dom_id(category, value)}"
  end

  defp active_filter_dom_id(category, value) do
    "active-filter-#{category}-#{filter_value_dom_id(category, value)}"
  end

  defp filter_value_dom_id(:languages, value),
    do: value |> to_string() |> Base.url_encode64(padding: false)

  defp filter_value_dom_id(_category, value), do: value

  defp parse_sort_direction(direction, _sort) when direction in ["asc", "desc"], do: direction
  defp parse_sort_direction(_direction, sort), do: default_sort_direction(sort)

  defp default_sort_direction(sort) when sort in ["title", "author_first", "author_last"],
    do: "asc"

  defp default_sort_direction(_sort), do: "desc"

  defp opposite_direction("asc"), do: "desc"
  defp opposite_direction(_direction), do: "asc"

  defp sort_label(sort) do
    @sort_options |> Enum.find(&(&1.id == sort)) |> Map.fetch!(:label)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} socket={@socket} active={:library}>
      <div class="space-y-6">
        <div class="grid items-center gap-4 lg:grid-cols-[1fr_minmax(20rem,28rem)_1fr]">
          <div>
            <h1 class="text-2xl font-bold">Library</h1>
            <p class="text-sm text-base-content/60">{Format.count(@book_count, "book")}</p>
          </div>

          <div
            id="library-search"
            class="relative w-full lg:justify-self-center"
            phx-click-away="close_search"
            phx-window-keydown="close_search"
            phx-key="escape"
          >
            <form
              id="library-search-form"
              phx-change="search"
              phx-submit="search"
              class="group relative"
            >
              <.icon
                name="hero-magnifying-glass"
                class="absolute left-4 top-1/2 size-4 -translate-y-1/2 text-[var(--pg-muted)] transition group-focus-within:text-primary"
              />
              <input
                type="search"
                name="search"
                value={@search}
                placeholder="Search books and library metadata"
                phx-debounce="250"
                phx-focus="open_search"
                aria-controls="library-search-results"
                aria-expanded={@search_open?}
                autocomplete="off"
                class="w-full rounded-xl border border-[var(--pg-border)] bg-[var(--pg-surface)] py-2.5 pl-11 pr-11 text-sm text-base-content shadow-sm outline-none transition placeholder:text-base-content/35 hover:border-primary/30 focus:border-primary/60 focus:ring-2 focus:ring-primary/15"
              />
              <button
                :if={@search != ""}
                id="clear-library-search"
                type="button"
                phx-click="clear_search"
                aria-label="Clear search"
                class="absolute right-2 top-1/2 grid size-8 -translate-y-1/2 place-items-center rounded-lg text-base-content/40 transition hover:bg-base-200 hover:text-base-content"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </form>

            <section
              :if={@search_open?}
              id="library-search-results"
              role="region"
              aria-label="Library search results"
              class="absolute inset-x-0 top-[calc(100%+0.5rem)] z-50 max-h-[min(38rem,calc(100dvh-8rem))] overflow-y-auto rounded-2xl border border-[var(--pg-border)] bg-[var(--pg-surface-raised)] p-2 shadow-2xl"
            >
              <div
                :if={@search_results == []}
                id="library-search-no-results"
                class="px-4 py-10 text-center text-sm text-base-content/50"
              >
                No matching books or metadata
              </div>

              <div
                :for={group <- @search_results}
                id={"search-group-#{group.id}"}
                class="mb-2 last:mb-0"
              >
                <div class="flex items-center gap-2 px-3 pb-1 pt-2 text-[11px] font-bold uppercase tracking-[0.12em] text-[var(--pg-muted)]">
                  <.icon name={group.icon} class="size-3.5" />
                  {group.label}
                </div>

                <%= if group.id == :books do %>
                  <.link
                    :for={book <- group.items}
                    id={"search-result-book-#{book.id}"}
                    navigate={~p"/books/#{book.id}"}
                    class="flex items-center gap-3 rounded-xl px-3 py-2.5 transition hover:bg-primary/10 focus-visible:bg-primary/10 focus-visible:outline-none"
                  >
                    <div class="size-12 shrink-0 overflow-hidden rounded-lg bg-base-300 shadow-sm">
                      <img
                        src={~p"/books/#{book.id}/cover"}
                        alt=""
                        class="size-full object-cover"
                        onerror="this.style.visibility='hidden'"
                      />
                    </div>
                    <div class="min-w-0">
                      <div class="truncate text-sm font-semibold">{book.name}</div>
                      <div :if={book.detail != ""} class="truncate text-xs text-[var(--pg-muted)]">
                        by {book.detail}
                      </div>
                    </div>
                  </.link>
                <% else %>
                  <.link
                    :for={item <- group.items}
                    id={"search-result-#{group.id}-#{filter_value_dom_id(group.id, item.id)}"}
                    navigate={search_filter_path(group.id, item.id, @sort, @sort_direction)}
                    class="flex items-center gap-3 rounded-xl px-3 py-2.5 transition hover:bg-primary/10 focus-visible:bg-primary/10 focus-visible:outline-none"
                  >
                    <span class="grid size-9 shrink-0 place-items-center rounded-lg bg-[var(--pg-tab)] text-primary">
                      <.icon name={group.icon} class="size-4" />
                    </span>
                    <span class="min-w-0">
                      <span class="block truncate text-sm font-medium">{item.name}</span>
                      <span class="block text-xs text-[var(--pg-muted)]">
                        {Format.count(item.book_count, "book")}
                      </span>
                    </span>
                  </.link>
                <% end %>
              </div>
            </section>
          </div>

          <div class="relative flex flex-wrap items-center gap-3 lg:justify-end">
            <div class="relative">
              <button
                id="library-sort-button"
                type="button"
                phx-click="open_sort"
                aria-haspopup="menu"
                aria-expanded={@sort_open?}
                class="inline-flex items-center gap-2 rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm font-medium transition hover:border-primary/40 hover:bg-base-200"
              >
                <.icon name="hero-arrows-up-down" class="size-4 text-base-content/55" />
                <span>{sort_label(@sort)}</span>
                <.icon
                  :if={@sort != "random"}
                  name={if(@sort_direction == "asc", do: "hero-arrow-up", else: "hero-arrow-down")}
                  class="size-3.5 text-primary"
                />
              </button>

              <div
                :if={@sort_open?}
                id="library-sort-backdrop"
                phx-click="close_sort"
                class="fixed inset-0 z-[60] bg-black/45 backdrop-blur-[2px] sm:bg-transparent sm:backdrop-blur-none"
              />

              <section
                :if={@sort_open?}
                id="library-sort-panel"
                role="menu"
                phx-window-keydown="close_sort"
                phx-key="escape"
                class="fixed inset-x-3 top-20 z-[70] flex max-h-[calc(100dvh-6rem)] flex-col overflow-hidden rounded-2xl border border-[var(--pg-border)] bg-[var(--pg-surface-raised)] shadow-2xl sm:absolute sm:inset-auto sm:right-0 sm:top-12 sm:w-80"
              >
                <header class="border-b border-[var(--pg-border)] px-4 py-3">
                  <p class="font-semibold">Sort library</p>
                  <p class="text-xs text-base-content/55">Choose a field and direction</p>
                </header>

                <div class="min-h-0 overflow-y-auto p-2">
                  <button
                    :if={@sort != "random"}
                    id="sort-direction-toggle"
                    type="button"
                    phx-click="toggle_sort_direction"
                    class="mb-2 flex w-full items-center justify-between rounded-lg border border-primary/20 bg-primary/8 px-3 py-2.5 text-left transition hover:border-primary/40 hover:bg-primary/12"
                  >
                    <span>
                      <span class="block text-xs font-medium uppercase tracking-wide text-base-content/45">
                        Direction
                      </span>
                      <span class="text-sm font-semibold text-primary">
                        {if(@sort_direction == "asc", do: "Ascending", else: "Descending")}
                      </span>
                    </span>
                    <span class="grid size-8 place-items-center rounded-lg bg-primary text-primary-content shadow-sm">
                      <.icon
                        name={
                          if(@sort_direction == "asc", do: "hero-arrow-up", else: "hero-arrow-down")
                        }
                        class="size-4"
                      />
                    </span>
                  </button>

                  <button
                    :for={option <- @sort_options}
                    id={"sort-option-#{option.id}"}
                    type="button"
                    role="menuitemradio"
                    aria-checked={@sort == option.id}
                    phx-click="select_sort"
                    phx-value-sort={option.id}
                    class={[
                      "flex w-full items-center gap-3 rounded-lg px-3 py-2.5 text-left text-sm transition",
                      if(@sort == option.id,
                        do: "bg-primary/12 font-semibold text-primary",
                        else: "text-base-content/70 hover:bg-base-200 hover:text-base-content"
                      )
                    ]}
                  >
                    <.icon name={option.icon} class="size-4" />
                    <span>{option.label}</span>
                    <.icon :if={@sort == option.id} name="hero-check" class="ml-auto size-4" />
                  </button>
                </div>
              </section>
            </div>

            <button
              id="library-filters-button"
              type="button"
              phx-click="open_filters"
              class={[
                "inline-flex items-center gap-2 rounded-lg border px-3 py-2 text-sm font-medium transition",
                if(@active_filter_count > 0,
                  do: "border-primary/50 bg-primary/10 text-primary hover:bg-primary/15",
                  else: "border-base-300 bg-base-100 hover:border-primary/40 hover:bg-base-200"
                )
              ]}
            >
              <.icon name="hero-funnel" class="size-4" /> Filters
              <span
                :if={@active_filter_count > 0}
                id="library-filter-count"
                class="grid size-5 place-items-center rounded-full bg-primary text-[11px] font-bold text-primary-content"
              >
                {@active_filter_count}
              </span>
            </button>

            <div
              :if={@filters_open?}
              id="library-filter-backdrop"
              phx-click="close_filters"
              class="fixed inset-0 z-[60] bg-black/45 backdrop-blur-[2px] sm:bg-transparent sm:backdrop-blur-none"
            />

            <section
              :if={@filters_open?}
              id="library-filter-panel"
              phx-window-keydown="close_filters"
              phx-key="escape"
              class="fixed inset-x-3 top-20 z-[70] flex max-h-[calc(100dvh-6rem)] flex-col overflow-hidden rounded-2xl border border-[var(--pg-border)] bg-[var(--pg-surface-raised)] shadow-2xl sm:absolute sm:inset-auto sm:right-0 sm:top-12 sm:h-[30rem] sm:w-[38rem]"
            >
              <header class="flex items-center justify-between border-b border-[var(--pg-border)] px-4 py-3">
                <div>
                  <h2 class="font-semibold">Filter library</h2>
                  <p class="text-xs text-base-content/55">
                    Choose multiple values to narrow your books
                  </p>
                </div>
                <div class="flex items-center gap-2">
                  <button
                    :if={@active_filter_count > 0}
                    id="clear-all-filters"
                    type="button"
                    phx-click="clear_filters"
                    class="rounded-md px-2 py-1 text-xs font-semibold text-primary transition hover:bg-primary/10"
                  >
                    Clear all
                  </button>
                  <button
                    id="close-library-filters"
                    type="button"
                    phx-click="close_filters"
                    aria-label="Close filters"
                    class="grid size-8 place-items-center rounded-lg text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
                  >
                    <.icon name="hero-x-mark" class="size-5" />
                  </button>
                </div>
              </header>

              <div class="grid min-h-0 flex-1 grid-cols-[8.5rem_1fr] sm:grid-cols-[11rem_1fr]">
                <nav
                  id="filter-categories"
                  class="min-h-0 overflow-y-auto border-r border-[var(--pg-border)] bg-[var(--pg-surface)] p-2"
                >
                  <button
                    :for={category <- @filter_categories}
                    id={"filter-category-#{category.id}"}
                    type="button"
                    phx-click="select_filter_category"
                    phx-value-category={category.id}
                    class={[
                      "mb-1 flex w-full items-center gap-2 rounded-lg px-2.5 py-2 text-left text-sm transition sm:px-3",
                      if(@active_filter == category.id,
                        do: "bg-primary/12 font-semibold text-primary",
                        else: "text-base-content/65 hover:bg-base-200 hover:text-base-content"
                      )
                    ]}
                  >
                    <.icon name={category.icon} class="size-4 shrink-0" />
                    <span class="truncate">{category.label}</span>
                    <span
                      :if={length(Map.fetch!(@filters, category.id)) > 0}
                      class="ml-auto text-xs font-bold"
                    >
                      {length(Map.fetch!(@filters, category.id))}
                    </span>
                  </button>
                </nav>

                <div class="flex min-w-0 flex-col">
                  <div class="border-b border-[var(--pg-border)] p-3">
                    <div class="mb-2 flex items-center justify-between gap-3">
                      <h3 class="font-semibold">{category_label(@active_filter)}</h3>
                      <button
                        :if={Map.fetch!(@filters, @active_filter) != []}
                        id="clear-current-filter"
                        type="button"
                        phx-click="clear_filter"
                        phx-value-category={@active_filter}
                        class="text-xs font-semibold text-primary hover:underline"
                      >
                        Clear
                      </button>
                    </div>
                    <form id="filter-options-search" phx-change="filter_options">
                      <div class="relative">
                        <.icon
                          name="hero-magnifying-glass"
                          class="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-base-content/40"
                        />
                        <input
                          type="search"
                          name="filter_search"
                          value={@filter_search}
                          placeholder={"Search #{String.downcase(category_label(@active_filter))}"}
                          phx-debounce="200"
                          class="w-full rounded-lg border border-base-300 bg-base-100 py-2 pl-9 pr-3 text-sm focus:border-primary focus:outline-none"
                        />
                      </div>
                    </form>
                  </div>

                  <div id="filter-options" class="min-h-0 flex-1 overflow-y-auto p-2">
                    <p
                      :if={
                        visible_filter_options(@filter_options, @active_filter, @filter_search) == []
                      }
                      class="px-3 py-8 text-center text-sm text-base-content/50"
                    >
                      No options found
                    </p>
                    <label
                      :for={
                        option <-
                          visible_filter_options(@filter_options, @active_filter, @filter_search)
                      }
                      for={filter_option_dom_id(@active_filter, option.id)}
                      class="group flex w-full items-center gap-3 rounded-lg px-3 py-2 text-left text-sm transition hover:bg-base-200"
                    >
                      <input
                        id={filter_option_dom_id(@active_filter, option.id)}
                        type="checkbox"
                        value={option.id}
                        checked={to_string(option.id) in Map.fetch!(@filters, @active_filter)}
                        phx-click="toggle_filter"
                        phx-value-category={@active_filter}
                        phx-value-id={option.id}
                        class="peer sr-only"
                      />
                      <span class="grid size-5 shrink-0 place-items-center rounded-md border border-base-300 bg-base-100 transition group-hover:border-primary/50 peer-checked:border-primary peer-checked:bg-primary peer-checked:text-primary-content">
                        <.icon
                          :if={to_string(option.id) in Map.fetch!(@filters, @active_filter)}
                          name="hero-check"
                          class="size-3.5"
                        />
                      </span>
                      <span class="truncate">{option.name}</span>
                    </label>
                  </div>
                </div>
              </div>
            </section>
          </div>
        </div>

        <div
          :if={@selected_filters != []}
          id="active-library-filters"
          class="flex flex-wrap items-center gap-2"
        >
          <span class="text-xs font-semibold uppercase tracking-wide text-base-content/45">Filtered by</span>
          <button
            :for={filter <- @selected_filters}
            id={active_filter_dom_id(filter.category, filter.value)}
            type="button"
            phx-click="toggle_filter"
            phx-value-category={filter.category}
            phx-value-id={filter.value}
            class="inline-flex items-center gap-1.5 rounded-full border border-primary/25 bg-primary/10 px-2.5 py-1 text-xs font-medium text-primary transition hover:border-primary/45 hover:bg-primary/15"
          >
            {filter.label}
            <.icon name="hero-x-mark" class="size-3.5" />
          </button>
          <button
            type="button"
            phx-click="clear_filters"
            class="px-1 text-xs text-base-content/55 hover:text-base-content hover:underline"
          >
            Clear all
          </button>
        </div>

        <div
          id="library-grid"
          phx-update="stream"
          class="grid gap-5 [grid-template-columns:repeat(auto-fill,minmax(var(--book-cover-size),var(--book-cover-size)))]"
          style={"--book-cover-size: #{@cover_size}px"}
        >
          <div
            id="library-empty"
            class="col-span-full hidden only:block rounded-xl border border-dashed border-base-300 p-12 text-center text-base-content/60"
          >
            <%= if @active_filter_count > 0 or @search != "" do %>
              No books match the current search and filters.
            <% else %>
              No books found. Ask an admin to scan a library.
            <% end %>
          </div>

          <.book_card :for={{dom_id, book} <- @streams.books} id={dom_id} book={book} />
        </div>

        <.cover_size_control
          :if={@book_count > 0}
          size={@cover_size}
          min={@cover_size_min}
          max={@cover_size_max}
          raised={@cover_size_control_raised?}
        />
      </div>
    </Layouts.app>
    """
  end
end
