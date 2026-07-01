defmodule PagelessWeb.HomeLive do
  use PagelessWeb, :live_view

  alias Pageless.Library
  alias Pageless.Library.Events
  alias Pageless.Playback
  alias Pageless.Accounts
  alias Pageless.Accounts.PlayerSettings
  alias PagelessWeb.PlayerLive

  @cover_size_step 20

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    settings = Accounts.get_player_settings(scope.user)

    if connected?(socket) do
      Events.subscribe(scope)
      Phoenix.PubSub.subscribe(Pageless.PubSub, PlayerLive.state_topic(scope.user.id))
      PlayerLive.request_state(scope.user.id)
    end

    {:ok,
     socket
     |> assign(page_title: "Home")
     |> assign(
       cover_size: settings.cover_size,
       cover_size_min: PlayerSettings.cover_size_min(),
       cover_size_max: PlayerSettings.cover_size_max(),
       cover_size_control_raised?: false
     )
     |> load_catalog()}
  end

  @impl true
  def handle_info({:player_state, state}, socket) do
    {:noreply, assign(socket, cover_size_control_raised?: not is_nil(Map.get(state, :book_id)))}
  end

  def handle_info({:catalog_changed, _changes}, socket) do
    {:noreply, load_catalog(socket)}
  end

  @impl true
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

  defp load_catalog(socket) do
    scope = socket.assigns.current_scope
    continue = Enum.map(Playback.continue_listening(scope), &decorate/1)
    finished = Enum.map(Playback.finished_books(scope), &decorate/1)

    # Discover surfaces new books; hide anything already started or finished so it
    # doesn't overlap with the other shelves.
    seen_ids = MapSet.new(Playback.book_ids_with_progress(scope))

    discover =
      scope
      |> Library.recently_added(12)
      |> Enum.reject(&MapSet.member?(seen_ids, &1.id))
      |> Enum.map(&decorate_book/1)

    assign(socket, continue: continue, finished: finished, discover: discover)
  end

  defp decorate({book, progress}) do
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

  defp decorate_book(book) do
    %{
      id: book.id,
      title: book.title,
      authors: Enum.map_join(book.authors, ", ", & &1.name),
      cover_version: book.updated_at,
      duration: book.duration_seconds,
      progress_pct: 0,
      finished: false
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} socket={@socket} active={:home}>
      <div class="space-y-10">
        <.shelf
          :if={@continue != []}
          id="shelf-continue"
          title="Continue Listening"
          books={@continue}
          cover_size={@cover_size}
        />
        <.shelf
          :if={@discover != []}
          id="shelf-discover"
          title="Discover"
          books={@discover}
          cover_size={@cover_size}
        />
        <.shelf
          :if={@finished != []}
          id="shelf-finished"
          title="Listen Again"
          books={@finished}
          cover_size={@cover_size}
        />

        <div
          :if={@continue == [] and @discover == [] and @finished == []}
          class="rounded-xl border border-dashed border-base-300 p-12 text-center text-base-content/60"
        >
          Nothing here yet. Visit the
          <.link navigate={~p"/library"} class="text-primary hover:underline">Library</.link>
          to start listening.
        </div>

        <.cover_size_control
          :if={@continue != [] or @discover != [] or @finished != []}
          size={@cover_size}
          min={@cover_size_min}
          max={@cover_size_max}
          raised={@cover_size_control_raised?}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :books, :list, required: true
  attr :cover_size, :integer, required: true

  defp shelf(assigns) do
    ~H"""
    <section id={@id} class="space-y-3">
      <h2 class="text-lg font-semibold">{@title}</h2>
      <div class="flex gap-5 overflow-x-auto pb-2" style={"--book-cover-size: #{@cover_size}px"}>
        <.book_card :for={book <- @books} book={book} class="w-[var(--book-cover-size)] shrink-0" />
      </div>
    </section>
    """
  end
end
