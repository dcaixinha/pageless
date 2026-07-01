defmodule PagelessWeb.LibraryLive.Collections do
  use PagelessWeb, :live_view

  alias Pageless.Format
  alias Pageless.Library
  alias Pageless.Library.Events

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe(socket.assigns.current_scope)
    {:ok, assign(socket, add_query: "", add_results: [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_info({:catalog_changed, _changes}, socket) do
    {:noreply, refresh_catalog(socket)}
  end

  defp refresh_catalog(%{assigns: %{live_action: :index}} = socket) do
    apply_action(socket, :index, %{})
  end

  defp refresh_catalog(socket) do
    case Library.get_collection(socket.assigns.current_scope, socket.assigns.collection.id) do
      nil -> push_navigate(socket, to: ~p"/collections")
      collection -> socket |> assign_collection_books(collection) |> refresh_add_results()
    end
  end

  defp apply_action(socket, :index, _params) do
    collections = Library.list_collections(socket.assigns.current_scope)

    socket
    |> assign(page_title: "Collections", collection: nil)
    |> assign(collections: Enum.map(collections, &decorate_collection/1))
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    case Library.get_collection(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, "Collection not found.")
        |> push_navigate(to: ~p"/collections")

      collection ->
        socket
        |> assign(page_title: collection.name)
        |> assign(add_query: "", add_results: [])
        |> assign_collection_books(collection)
    end
  end

  @impl true
  def handle_event("remove_book", %{"book-id" => book_id}, socket) do
    Library.remove_book_from_collection(
      socket.assigns.current_scope,
      socket.assigns.collection.id,
      book_id
    )

    {:noreply, socket |> reload_collection() |> refresh_add_results()}
  end

  def handle_event("search_books", %{"query" => query}, socket) do
    {:noreply, socket |> assign(add_query: query) |> refresh_add_results()}
  end

  def handle_event("add_book", %{"book-id" => book_id}, socket) do
    case Library.add_book_to_collection(
           socket.assigns.current_scope,
           socket.assigns.collection.id,
           book_id
         ) do
      {:ok, _} ->
        {:noreply, socket |> reload_collection() |> refresh_add_results()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not add book to collection.")}
    end
  end

  defp reload_collection(socket) do
    collection =
      Library.get_collection(socket.assigns.current_scope, socket.assigns.collection.id)

    assign_collection_books(socket, collection)
  end

  defp assign_collection_books(socket, collection) do
    assign(socket,
      collection: collection,
      books: Enum.map(collection.book_collections, &decorate_book(&1.book))
    )
  end

  # Search results for the "add books" box, limited to the collection's library
  # and excluding books already present.
  defp refresh_add_results(socket) do
    query = String.trim(socket.assigns.add_query)
    collection = socket.assigns.collection

    results =
      if query == "" do
        []
      else
        existing = MapSet.new(collection.book_collections, & &1.book_id)

        socket.assigns.current_scope
        |> Library.list_books(search: query, sort: :title, library_id: collection.library_id)
        |> Enum.reject(&MapSet.member?(existing, &1.id))
        |> Enum.take(10)
        |> Enum.map(&decorate_book/1)
      end

    assign(socket, add_results: results)
  end

  defp decorate_collection(collection) do
    books = Enum.map(collection.book_collections, & &1.book)

    %{
      id: collection.id,
      name: collection.name,
      book_count: length(books),
      cover_book_ids: books |> Enum.take(4) |> Enum.map(& &1.id)
    }
  end

  defp decorate_book(book) do
    %{
      id: book.id,
      title: book.title,
      authors: Enum.map_join(book.authors, ", ", & &1.name),
      cover_version: book.updated_at
    }
  end

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} socket={@socket} active={:collections}>
      <div class="space-y-6">
        <div>
          <h1 class="text-2xl font-bold">Collections</h1>
          <p class="text-sm text-base-content/60">
            {Format.count(length(@collections), "collection")}
          </p>
        </div>

        <div
          :if={@collections == []}
          class="rounded-xl border border-dashed border-base-300 p-12 text-center text-base-content/60"
        >
          No collections yet. Import them from Audiobookshelf to get started.
        </div>

        <div class="grid gap-5 [grid-template-columns:repeat(auto-fill,minmax(180px,1fr))]">
          <.link
            :for={collection <- @collections}
            id={"collection-#{collection.id}"}
            navigate={~p"/collections/#{collection.id}"}
            class="group block"
          >
            <div class="grid aspect-square grid-cols-2 grid-rows-2 overflow-hidden rounded-[10px] bg-[color:var(--pg-surface-raised)] shadow-sm transition duration-200 group-hover:-translate-y-0.5 group-hover:shadow-lg">
              <img
                :for={book_id <- collection.cover_book_ids}
                src={~p"/books/#{book_id}/cover"}
                alt=""
                loading="lazy"
                class="size-full object-cover"
                onerror="this.style.visibility='hidden'"
              />
            </div>
            <div class="mt-2">
              <div class="truncate text-sm font-medium group-hover:text-primary">
                {collection.name}
              </div>
              <div class="text-xs text-[color:var(--pg-muted)]">
                {Format.count(collection.book_count, "book")}
              </div>
            </div>
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def render(%{live_action: :show} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} socket={@socket} active={:collections}>
      <div class="space-y-6">
        <div>
          <.link
            navigate={~p"/collections"}
            class="inline-flex items-center gap-1 text-sm text-[color:var(--pg-muted)] hover:text-primary"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Back to collections
          </.link>
          <h1 class="mt-2 text-2xl font-bold">{@collection.name}</h1>
          <p :if={@collection.description} class="mt-1 text-sm text-base-content/70">
            {@collection.description}
          </p>
          <p class="text-sm text-base-content/60">{Format.count(length(@books), "book")}</p>
        </div>

        <div class="rounded-xl border border-base-300 bg-[color:var(--pg-surface)] p-4">
          <form phx-change="search_books" phx-submit="search_books" id="collection-add-form">
            <div class="relative">
              <.icon
                name="hero-magnifying-glass"
                class="size-4 absolute left-3 top-1/2 -translate-y-1/2 text-base-content/40"
              />
              <input
                type="text"
                name="query"
                value={@add_query}
                placeholder="Search books to add…"
                phx-debounce="250"
                autocomplete="off"
                class="w-full rounded-lg border border-base-300 bg-base-100 py-2 pl-9 pr-3 text-sm focus:border-primary focus:outline-none"
              />
            </div>
          </form>

          <ul :if={@add_results != []} class="mt-3 divide-y divide-base-200">
            <li
              :for={book <- @add_results}
              id={"add-result-#{book.id}"}
              class="flex items-center gap-3 py-2"
            >
              <img
                src={~p"/books/#{book.id}/cover"}
                alt=""
                loading="lazy"
                class="size-10 shrink-0 rounded object-cover"
                onerror="this.style.visibility='hidden'"
              />
              <div class="min-w-0 flex-1">
                <div class="truncate text-sm font-medium">{book.title}</div>
                <div class="truncate text-xs text-[color:var(--pg-muted)]">{book.authors}</div>
              </div>
              <button
                type="button"
                phx-click="add_book"
                phx-value-book-id={book.id}
                class="inline-flex shrink-0 items-center gap-1 rounded-lg bg-primary px-3 py-1.5 text-sm font-medium text-primary-content hover:opacity-90"
              >
                <.icon name="hero-plus" class="size-4" /> Add
              </button>
            </li>
          </ul>

          <p :if={@add_query != "" and @add_results == []} class="mt-3 text-sm text-base-content/60">
            No matching books found in this library.
          </p>
        </div>

        <div
          :if={@books == []}
          class="rounded-xl border border-dashed border-base-300 p-12 text-center text-base-content/60"
        >
          This collection is empty. Search above to add books.
        </div>

        <div class="grid gap-5 [grid-template-columns:repeat(auto-fill,minmax(160px,1fr))]">
          <div :for={book <- @books} class="group/item relative">
            <button
              type="button"
              phx-click="remove_book"
              phx-value-book-id={book.id}
              aria-label={"Remove #{book.title}"}
              class="absolute right-2 top-2 z-10 hidden size-7 items-center justify-center rounded-full bg-black/60 text-white group-hover/item:flex hover:bg-error"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
            <.book_card id={"collection-book-#{book.id}"} book={book} />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
