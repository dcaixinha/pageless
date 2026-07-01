defmodule PagelessWeb.PlayerLive do
  @moduledoc """
  The persistent audio player. It is rendered once in the app layout with
  `sticky: true` so it survives navigation between LiveViews.

  Other LiveViews request playback by broadcasting on the per-user topic
  returned by `topic/1`; this LiveView subscribes on mount and pushes a `"play"`
  event to the `AudioPlayer` JS hook.
  """
  use PagelessWeb, :live_view

  on_mount {PagelessWeb.UserAuth, :mount_current_scope}

  alias Pageless.Accounts
  alias Pageless.Accounts.PlayerSettings
  alias Pageless.Library
  alias Pageless.Library.Chapters
  alias Pageless.Playback
  alias PagelessWeb.AudioController
  alias Pageless.Format

  @doc "Per-user PubSub topic for player control messages."
  def topic(user_id), do: "player:#{user_id}"

  @doc """
  Per-user PubSub topic the player publishes its current state on, so other
  views (e.g. the book page) can reflect what is playing.
  """
  def state_topic(user_id), do: "player_state:#{user_id}"

  @doc """
  Broadcasts a request to play a book (optionally seeking to `start`).

  Options:

    * `:preview` - when `true`, listening progress is NOT persisted. Useful for
      auditioning a position (e.g. while editing chapters) without affecting the
      user's saved place in the book. Defaults to `false`.
  """
  def play(user_id, book_id, start \\ nil, opts \\ []) do
    preview? = Keyword.get(opts, :preview, false)

    Phoenix.PubSub.broadcast(
      Pageless.PubSub,
      topic(user_id),
      {:play_book, book_id, start, preview?}
    )
  end

  @doc """
  Asks the running player to (re)broadcast its current state. Useful when a view
  mounts and wants to know what is already playing.
  """
  def request_state(user_id) do
    Phoenix.PubSub.broadcast(Pageless.PubSub, topic(user_id), :request_player_state)
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) and user(socket) do
      Phoenix.PubSub.subscribe(Pageless.PubSub, topic(user(socket).id))
    end

    settings = Accounts.get_player_settings(user(socket))
    user_agent = if connected?(socket), do: get_connect_params(socket)["user_agent"], else: nil

    {:ok,
     socket
     |> assign(book: nil, playing: false, position: 0.0, speed: settings.playback_rate)
     |> assign(token: nil, settings: settings, show_settings: false, show_chapters: false)
     |> assign(show_bookmarks: false, bookmarks: [])
     |> assign(
       listening_session_id: nil,
       listening_started_at_ms: nil,
       listening_session_book_id: nil,
       user_agent: user_agent
     )
     |> assign(preview?: false), layout: false}
  end

  defp user(socket), do: socket.assigns.current_scope && socket.assigns.current_scope.user

  @impl true
  def terminate(_reason, socket) do
    socket
    |> maybe_flush_listening_time(socket.assigns.position)
    |> record_listening_event("Stop")
    |> end_listening_session()

    :ok
  end

  @impl true
  def handle_info({:play_book, book_id, start, preview?}, socket) do
    socket = maybe_end_session_for_new_book(socket, book_id, preview?)
    book = Library.get_book!(socket.assigns.current_scope, book_id)

    resume =
      case start do
        nil -> Playback.resume_position(socket.assigns.current_scope, book.id)
        s -> s
      end

    token = AudioController.sign_token(PagelessWeb.Endpoint, user(socket).id, book.id)

    {:noreply,
     socket
     |> assign(book: book, token: token, playing: true, position: resume, preview?: preview?)
     |> broadcast_state()
     |> push_event("play", %{
       url: ~p"/books/#{book.id}/audio",
       token: token,
       position: resume,
       speed: socket.assigns.speed,
       title: book.title,
       artist: Enum.map_join(book.authors, ", ", & &1.name),
       duration: book.duration_seconds,
       chapters: chapters_payload(book),
       use_chapter_track: socket.assigns.settings.use_chapter_track
     })}
  end

  def handle_info(:request_player_state, socket) do
    {:noreply, broadcast_state(socket)}
  end

  def handle_info(:toggle_playback, %{assigns: %{book: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_info(:toggle_playback, socket) do
    playing = not socket.assigns.playing
    event = if playing, do: "resume", else: "pause"

    {:noreply, socket |> assign(playing: playing) |> broadcast_state() |> push_event(event, %{})}
  end

  # Publishes the current play state so other views can reflect it.
  defp broadcast_state(socket) do
    if user = user(socket) do
      payload = %{
        book_id: socket.assigns.book && socket.assigns.book.id,
        playing: socket.assigns.playing,
        position: socket.assigns.position
      }

      Phoenix.PubSub.broadcast(
        Pageless.PubSub,
        state_topic(user.id),
        {:player_state, payload}
      )
    end

    socket
  end

  defp chapters_payload(book) do
    Enum.map(book.chapters, fn ch ->
      %{
        index: ch.index,
        title: ch.title || "Chapter #{ch.index + 1}",
        start: ch.start_seconds,
        end: ch.end_seconds
      }
    end)
  end

  @impl true
  def handle_event("toggle", _params, %{assigns: %{book: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("toggle", _params, socket) do
    playing = not socket.assigns.playing
    event = if playing, do: "resume", else: "pause"

    {:noreply, socket |> assign(playing: playing) |> broadcast_state() |> push_event(event, %{})}
  end

  def handle_event("seek", %{"position" => position}, socket) do
    position = parse_float(position, 0.0)

    {:noreply,
     socket
     |> record_listening_event("Seek", position)
     |> push_event("seek", %{position: position})}
  end

  def handle_event("set_speed", %{"speed" => speed}, socket) do
    {:noreply, apply_speed(socket, parse_float(speed, 1.0))}
  end

  def handle_event("step_speed", %{"dir" => dir}, socket) do
    step = socket.assigns.settings.rate_increment * parse_float(dir, 1.0)
    speed = (socket.assigns.speed + step) |> Float.round(2) |> clamp_speed()
    {:noreply, apply_speed(socket, speed)}
  end

  def handle_event("nudge", %{"delta" => delta}, socket) do
    position = socket.assigns.position + parse_float(delta, 0.0)

    {:noreply,
     socket
     |> record_listening_event("Seek", position)
     |> push_event("nudge", %{delta: parse_float(delta, 0.0)})}
  end

  def handle_event("next_chapter", _params, socket), do: jump_chapter(socket, +1)
  def handle_event("prev_chapter", _params, socket), do: jump_chapter(socket, -1)

  # Progress ticks from the hook: persist position and keep UI in sync.
  # In preview mode (e.g. auditioning chapters) we don't persist progress so the
  # user's saved place in the book is untouched.
  def handle_event("progress", %{"position" => position, "duration" => duration}, socket) do
    if (book = socket.assigns.book) && not socket.assigns.preview? do
      Playback.save_progress(socket.assigns.current_scope, book.id, position, duration)
    end

    {:noreply,
     socket
     |> assign(position: position)
     |> maybe_flush_listening_time(position)
     |> broadcast_state()}
  end

  def handle_event("position", %{"position" => position}, socket) do
    {:noreply, socket |> assign(position: position) |> broadcast_state()}
  end

  def handle_event("ended", _params, socket) do
    {:noreply,
     socket
     |> maybe_flush_listening_time(socket.assigns.position)
     |> record_listening_event("Stop")
     |> end_listening_session()
     |> assign(playing: false)
     |> broadcast_state()}
  end

  def handle_event("playing", %{"playing" => playing}, socket) do
    socket =
      if playing do
        socket
        |> ensure_listening_session()
        |> record_listening_event("Play")
        |> assign(listening_started_at_ms: monotonic_ms())
      else
        socket
        |> maybe_flush_listening_time(socket.assigns.position)
        |> record_listening_event("Pause")
        |> assign(listening_started_at_ms: nil)
      end

    {:noreply, socket |> assign(playing: playing) |> broadcast_state()}
  end

  def handle_event("open_settings", _params, socket) do
    {:noreply, assign(socket, show_settings: true)}
  end

  def handle_event("close_settings", _params, socket) do
    {:noreply, assign(socket, show_settings: false)}
  end

  def handle_event("open_chapters", _params, socket) do
    {:noreply, assign(socket, show_chapters: true)}
  end

  def handle_event("close_chapters", _params, socket) do
    {:noreply, assign(socket, show_chapters: false)}
  end

  def handle_event("play_chapter", %{"start" => start}, socket) do
    position = parse_float(start, 0.0)

    {:noreply,
     socket
     |> record_listening_event("Seek", position)
     |> assign(show_chapters: false)
     |> push_event("seek", %{position: position})}
  end

  def handle_event("open_bookmarks", _params, %{assigns: %{book: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("open_bookmarks", _params, socket) do
    bookmarks = Playback.list_bookmarks(socket.assigns.current_scope, socket.assigns.book.id)
    {:noreply, assign(socket, show_bookmarks: true, bookmarks: bookmarks)}
  end

  def handle_event("close_bookmarks", _params, socket) do
    {:noreply, assign(socket, show_bookmarks: false)}
  end

  def handle_event("add_bookmark", params, %{assigns: %{book: book}} = socket)
      when not is_nil(book) do
    note = params["note"]

    case Playback.create_bookmark(
           socket.assigns.current_scope,
           book.id,
           socket.assigns.position,
           note
         ) do
      {:ok, _bookmark} ->
        bookmarks = Playback.list_bookmarks(socket.assigns.current_scope, book.id)
        {:noreply, assign(socket, bookmarks: bookmarks)}

      {:error, _changeset} ->
        {:noreply, socket}
    end
  end

  def handle_event("add_bookmark", _params, socket), do: {:noreply, socket}

  def handle_event("delete_bookmark", %{"id" => id}, socket) do
    Playback.delete_bookmark(socket.assigns.current_scope, id)

    bookmarks =
      if socket.assigns.book,
        do: Playback.list_bookmarks(socket.assigns.current_scope, socket.assigns.book.id),
        else: []

    {:noreply, assign(socket, bookmarks: bookmarks)}
  end

  def handle_event("play_bookmark", %{"position" => position}, socket) do
    position = parse_float(position, 0.0)

    {:noreply,
     socket
     |> record_listening_event("Seek", position)
     |> assign(show_bookmarks: false)
     |> push_event("seek", %{position: position})}
  end

  def handle_event("save_settings", %{"settings" => params}, socket) do
    case Accounts.update_player_settings(user(socket), params) do
      {:ok, updated_user} ->
        settings = updated_user.player_settings

        {:noreply,
         socket
         |> assign(settings: settings, current_scope: refresh_scope(socket, updated_user))
         |> push_event("settings", %{use_chapter_track: settings.use_chapter_track})}

      {:error, _changeset} ->
        {:noreply, socket}
    end
  end

  defp refresh_scope(socket, user) do
    %{socket.assigns.current_scope | user: user}
  end

  defp maybe_end_session_for_new_book(socket, _book_id, true), do: socket

  defp maybe_end_session_for_new_book(socket, book_id, false) do
    if socket.assigns.listening_session_id && socket.assigns.listening_session_book_id != book_id do
      socket
      |> maybe_flush_listening_time(socket.assigns.position)
      |> record_listening_event("Stop")
      |> end_listening_session()
    else
      socket
    end
  end

  defp ensure_listening_session(%{assigns: %{preview?: true}} = socket), do: socket
  defp ensure_listening_session(%{assigns: %{book: nil}} = socket), do: socket

  defp ensure_listening_session(%{assigns: %{listening_session_id: id}} = socket)
       when not is_nil(id), do: socket

  defp ensure_listening_session(socket) do
    device_info = "Pageless Web\n#{socket.assigns.user_agent || "Unknown browser"}"

    case Playback.start_listening_session(socket.assigns.current_scope, socket.assigns.book,
           play_method: "Direct Play",
           device_info: device_info,
           position_seconds: socket.assigns.position
         ) do
      {:ok, session} ->
        assign(socket,
          listening_session_id: session.id,
          listening_session_book_id: socket.assigns.book.id
        )

      {:error, _changeset} ->
        socket
    end
  end

  defp maybe_flush_listening_time(%{assigns: %{preview?: true}} = socket, _position), do: socket

  defp maybe_flush_listening_time(%{assigns: %{listening_session_id: nil}} = socket, _position),
    do: socket

  defp maybe_flush_listening_time(
         %{assigns: %{listening_started_at_ms: nil}} = socket,
         _position
       ),
       do: socket

  defp maybe_flush_listening_time(socket, position) do
    elapsed_seconds = div(max(monotonic_ms() - socket.assigns.listening_started_at_ms, 0), 1_000)

    if elapsed_seconds > 0 do
      Playback.add_listening_time(
        socket.assigns.current_scope,
        socket.assigns.listening_session_id,
        elapsed_seconds,
        position
      )

      assign(socket, listening_started_at_ms: monotonic_ms())
    else
      socket
    end
  end

  defp record_listening_event(socket, event, position \\ nil)

  defp record_listening_event(%{assigns: %{preview?: true}} = socket, _event, _position),
    do: socket

  defp record_listening_event(
         %{assigns: %{listening_session_id: nil}} = socket,
         _event,
         _position
       ),
       do: socket

  defp record_listening_event(%{assigns: %{book: nil}} = socket, _event, _position), do: socket

  defp record_listening_event(socket, event, position) do
    Playback.record_listening_event(
      socket.assigns.current_scope,
      socket.assigns.listening_session_id,
      socket.assigns.book.id,
      event,
      position || socket.assigns.position
    )

    socket
  end

  defp end_listening_session(%{assigns: %{listening_session_id: nil}} = socket), do: socket

  defp end_listening_session(socket) do
    Playback.end_listening_session(
      socket.assigns.current_scope,
      socket.assigns.listening_session_id,
      socket.assigns.position
    )

    assign(socket,
      listening_session_id: nil,
      listening_started_at_ms: nil,
      listening_session_book_id: nil
    )
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp jump_chapter(%{assigns: %{book: nil}} = socket, _dir), do: {:noreply, socket}

  defp jump_chapter(socket, dir) do
    chapters = socket.assigns.book.chapters
    position = socket.assigns.position

    target =
      case Chapters.current_index(chapters, position) do
        nil ->
          nil

        idx ->
          cond do
            # "Previous" while a few seconds into a chapter restarts it.
            dir == -1 and position - Enum.at(chapters, idx).start_seconds > 3 ->
              Enum.at(chapters, idx)

            true ->
              Enum.at(chapters, idx + dir)
          end
      end

    case target do
      nil -> {:noreply, socket}
      chapter -> {:noreply, push_event(socket, "seek", %{position: chapter.start_seconds})}
    end
  end

  defp parse_float(value, _default) when is_float(value), do: value
  defp parse_float(value, _default) when is_integer(value), do: value * 1.0

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {f, _} -> f
      :error -> default
    end
  end

  defp parse_float(_, default), do: default

  defp clamp_speed(speed), do: speed |> max(0.5) |> min(3.0)

  # Sets the speed, pushes it to the player, and persists it to the user's
  # settings so it is restored next time.
  defp apply_speed(socket, speed) do
    socket
    |> persist_setting(:playback_rate, speed)
    |> assign(speed: speed)
    |> push_event("set_speed", %{speed: speed})
  end

  defp persist_setting(socket, key, value) do
    with user when not is_nil(user) <- user(socket),
         {:ok, updated_user} <- Accounts.update_player_settings(user, %{key => value}) do
      socket
      |> assign(settings: updated_user.player_settings)
      |> assign(current_scope: refresh_scope(socket, updated_user))
    else
      _ -> socket
    end
  end

  defp format_speed(speed) do
    speed
    |> Float.round(2)
    |> :erlang.float_to_binary(decimals: 2)
    |> String.replace(~r/\.?0+$/, "")
    |> then(fn s -> if s == "", do: "0", else: s end)
  end

  attr :seconds, :integer, required: true
  attr :direction, :atom, values: [:back, :forward], required: true

  # A circular "replay/forward N seconds" icon with the seconds count centered
  # inside the arc, mirroring the Audiobookshelf player controls.
  defp skip_icon(assigns) do
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
        <%!-- replay arc: center 12,12 r8, opening at the top with an arrowhead --%>
        <path d="M12 4 a 8 8 0 1 0 5.66 2.34" />
        <polyline points="9 1.5 12 4 9.5 7" />
      </svg>
      <span class="absolute text-[8px] font-semibold leading-none tabular-nums">
        {@seconds}
      </span>
    </span>
    """
  end

  attr :direction, :atom, values: [:back, :forward], required: true

  # "Skip to previous/next track" icon: a filled triangle with a vertical bar,
  # used for chapter navigation.
  defp track_step_icon(assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      fill="currentColor"
      class={["size-5", @direction == :forward && "-scale-x-100"]}
      aria-hidden="true"
    >
      <path d="M5.5 5.25 a .75 .75 0 0 1 1.5 0 v13.5 a .75 .75 0 0 1 -1.5 0 z" />
      <path d="M8.5 11.36 18 5.55 a .75 .75 0 0 1 1.14 .64 v11.62 a .75 .75 0 0 1 -1.14 .64 L8.5 12.64 a .75 .75 0 0 1 0 -1.28 z" />
    </svg>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="player" phx-hook="AudioPlayer" class={[!@book && "hidden"]}>
      <audio></audio>

      <div class="fixed inset-x-0 bottom-0 z-40 border-t border-[color:var(--pg-border)] bg-[color:var(--pg-surface)] shadow-2xl backdrop-blur">
        <%= if @book do %>
          <div class="px-4 py-3 sm:px-6">
            <div class="flex items-center gap-4">
              <.link navigate={~p"/books/#{@book.id}"} class="shrink-0">
                <img
                  src={~p"/books/#{@book.id}/cover"}
                  alt={@book.title}
                  class="size-12 rounded-[10px] object-cover bg-[color:var(--pg-surface-raised)] transition hover:opacity-80"
                  onerror="this.style.visibility='hidden'"
                />
              </.link>

              <div class="hidden min-w-0 sm:block sm:w-48">
                <.link
                  navigate={~p"/books/#{@book.id}"}
                  class="block truncate text-sm font-medium hover:text-primary hover:underline"
                >
                  {@book.title}
                </.link>
                <div class="truncate text-xs text-base-content/60">
                  {Enum.map_join(@book.authors, ", ", & &1.name)}
                </div>
              </div>

              <div class="flex flex-1 items-center justify-center gap-2 sm:gap-4">
                <button
                  type="button"
                  phx-click="prev_chapter"
                  aria-label="Previous chapter"
                  class="flex size-9 items-center justify-center rounded-full text-base-content/70 hover:bg-base-200 hover:text-base-content transition"
                >
                  <.track_step_icon direction={:back} />
                </button>
                <button
                  type="button"
                  phx-click="nudge"
                  phx-value-delta={-@settings.jump_backward}
                  aria-label={"Back #{@settings.jump_backward} seconds"}
                  class="flex size-9 items-center justify-center rounded-full text-base-content/70 hover:bg-base-200 hover:text-base-content transition"
                >
                  <.skip_icon seconds={@settings.jump_backward} direction={:back} />
                </button>
                <button
                  type="button"
                  phx-click="toggle"
                  aria-label={if @playing, do: "Pause", else: "Play"}
                  class="flex size-11 shrink-0 items-center justify-center rounded-full bg-primary text-primary-content hover:opacity-90 transition"
                >
                  <.icon
                    name={if @playing, do: "hero-pause-solid", else: "hero-play-solid"}
                    class="size-6"
                  />
                </button>
                <button
                  type="button"
                  phx-click="nudge"
                  phx-value-delta={@settings.jump_forward}
                  aria-label={"Forward #{@settings.jump_forward} seconds"}
                  class="flex size-9 items-center justify-center rounded-full text-base-content/70 hover:bg-base-200 hover:text-base-content transition"
                >
                  <.skip_icon seconds={@settings.jump_forward} direction={:forward} />
                </button>
                <button
                  type="button"
                  phx-click="next_chapter"
                  aria-label="Next chapter"
                  class="flex size-9 items-center justify-center rounded-full text-base-content/70 hover:bg-base-200 hover:text-base-content transition"
                >
                  <.track_step_icon direction={:forward} />
                </button>
              </div>

              <div class="flex shrink-0 items-center gap-1">
                <button
                  type="button"
                  phx-click="step_speed"
                  phx-value-dir="-1"
                  aria-label="Decrease speed"
                  class="flex size-7 items-center justify-center rounded-full text-base-content/60 hover:bg-base-200 hover:text-base-content transition"
                >
                  <.icon name="hero-minus" class="size-4" />
                </button>
                <span class="w-10 text-center text-xs font-medium tabular-nums">
                  {format_speed(@speed)}x
                </span>
                <button
                  type="button"
                  phx-click="step_speed"
                  phx-value-dir="1"
                  aria-label="Increase speed"
                  class="flex size-7 items-center justify-center rounded-full text-base-content/60 hover:bg-base-200 hover:text-base-content transition"
                >
                  <.icon name="hero-plus" class="size-4" />
                </button>
              </div>

              <button
                type="button"
                phx-click="open_bookmarks"
                aria-label="View bookmarks"
                title="View bookmarks"
                class="flex size-9 shrink-0 items-center justify-center rounded-full text-base-content/70 hover:bg-base-200 hover:text-base-content transition"
              >
                <.icon name="hero-bookmark" class="size-5" />
              </button>

              <button
                :if={@book.chapters != []}
                type="button"
                phx-click="open_chapters"
                aria-label="View chapters"
                title="View chapters"
                class="flex size-9 shrink-0 items-center justify-center rounded-full text-base-content/70 hover:bg-base-200 hover:text-base-content transition"
              >
                <.icon name="hero-queue-list" class="size-5" />
              </button>

              <button
                type="button"
                phx-click="open_settings"
                aria-label="Player settings"
                title="View player settings"
                class="flex size-9 shrink-0 items-center justify-center rounded-full text-base-content/70 hover:bg-base-200 hover:text-base-content transition"
              >
                <.icon name="hero-cog-6-tooth" class="size-5" />
              </button>
            </div>

            <div class="mt-2">
              <div
                id="player-scrubber"
                phx-hook=".Scrubber"
                class="group relative h-2 w-full cursor-pointer rounded-full bg-base-300"
              >
                <div
                  id="player-progress"
                  phx-update="ignore"
                  class="h-full rounded-full bg-primary"
                  style="width: 0%"
                >
                </div>
              </div>

              <div class="mt-1 flex items-center justify-between text-xs text-base-content/60">
                <span id="player-chapter-elapsed" phx-update="ignore" class="tabular-nums">
                  0:00
                </span>
                <span
                  id="player-chapter-title"
                  phx-update="ignore"
                  class="truncate px-2 text-center font-medium text-base-content/80"
                ></span>
                <span id="player-chapter-remaining" phx-update="ignore" class="tabular-nums"></span>
              </div>
            </div>
          </div>
        <% else %>
          <div class="px-4 py-3 text-sm text-base-content/50 sm:px-6">Nothing playing</div>
        <% end %>
      </div>

      <%= if @show_settings do %>
        <div
          id="player-settings-modal"
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
          phx-window-keydown="close_settings"
          phx-key="escape"
        >
          <div
            class="absolute inset-0 bg-black/50"
            phx-click="close_settings"
            aria-hidden="true"
          >
          </div>

          <div
            role="dialog"
            aria-modal="true"
            aria-labelledby="player-settings-title"
            class="relative w-full max-w-sm rounded-2xl border border-base-300 bg-base-100 p-6 shadow-2xl"
          >
            <div class="mb-5 flex items-center justify-between">
              <h2 id="player-settings-title" class="text-lg font-semibold">Player Settings</h2>
              <button
                type="button"
                phx-click="close_settings"
                aria-label="Close"
                class="flex size-8 items-center justify-center rounded-full text-base-content/60 hover:bg-base-200 hover:text-base-content transition"
              >
                <.icon name="hero-x-mark" class="size-5" />
              </button>
            </div>

            <form id="player-settings-form" phx-change="save_settings" class="space-y-5">
              <label class="flex cursor-pointer items-center gap-3">
                <input type="hidden" name="settings[use_chapter_track]" value="false" />
                <input
                  type="checkbox"
                  name="settings[use_chapter_track]"
                  value="true"
                  checked={@settings.use_chapter_track}
                  class="peer sr-only"
                />
                <span class="relative h-6 w-11 rounded-full bg-base-300 transition peer-checked:bg-primary after:absolute after:left-0.5 after:top-0.5 after:size-5 after:rounded-full after:bg-base-100 after:shadow after:transition peer-checked:after:translate-x-5"></span>
                <span class="text-sm font-medium">Use chapter track</span>
              </label>

              <div>
                <label class="mb-1 block text-sm font-medium">Jump forward amount</label>
                <select
                  name="settings[jump_forward]"
                  class="w-full rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm focus:border-primary focus:outline-none"
                >
                  <option
                    :for={n <- PlayerSettings.jump_amounts()}
                    value={n}
                    selected={n == @settings.jump_forward}
                  >
                    {n} seconds
                  </option>
                </select>
              </div>

              <div>
                <label class="mb-1 block text-sm font-medium">Jump backward amount</label>
                <select
                  name="settings[jump_backward]"
                  class="w-full rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm focus:border-primary focus:outline-none"
                >
                  <option
                    :for={n <- PlayerSettings.jump_amounts()}
                    value={n}
                    selected={n == @settings.jump_backward}
                  >
                    {n} seconds
                  </option>
                </select>
              </div>

              <div>
                <label class="mb-1 block text-sm font-medium">
                  Playback Rate Increment/Decrement Amount
                </label>
                <select
                  name="settings[rate_increment]"
                  class="w-full rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm focus:border-primary focus:outline-none"
                >
                  <option
                    :for={n <- PlayerSettings.rate_increments()}
                    value={n}
                    selected={n == @settings.rate_increment}
                  >
                    {n}
                  </option>
                </select>
              </div>
            </form>
          </div>
        </div>
      <% end %>

      <%= if @show_chapters and @book do %>
        <% current_index = Chapters.current_index(@book.chapters, @position) %>
        <div
          id="player-chapters-modal"
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
          phx-window-keydown="close_chapters"
          phx-key="escape"
        >
          <div class="absolute inset-0 bg-black/50" phx-click="close_chapters" aria-hidden="true">
          </div>

          <div
            role="dialog"
            aria-modal="true"
            aria-labelledby="player-chapters-title"
            class="relative flex max-h-[80vh] w-full max-w-lg flex-col overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-2xl"
          >
            <div class="flex items-center justify-between border-b border-base-300 px-5 py-4">
              <h2 id="player-chapters-title" class="text-lg font-semibold">Chapters</h2>
              <button
                type="button"
                phx-click="close_chapters"
                aria-label="Close"
                class="flex size-8 items-center justify-center rounded-full text-base-content/60 hover:bg-base-200 hover:text-base-content transition"
              >
                <.icon name="hero-x-mark" class="size-5" />
              </button>
            </div>

            <ul class="divide-y divide-base-200 overflow-y-auto">
              <li :for={chapter <- @book.chapters}>
                <button
                  type="button"
                  phx-click="play_chapter"
                  phx-value-start={chapter.start_seconds}
                  class={[
                    "flex w-full items-center justify-between gap-3 px-5 py-3 text-left text-sm transition",
                    if(chapter.index == current_index,
                      do: "bg-primary/15 border-l-2 border-primary font-semibold",
                      else: "hover:bg-base-200"
                    )
                  ]}
                >
                  <span class="flex min-w-0 items-baseline gap-2">
                    <span class="truncate">
                      {chapter.title || "Chapter #{chapter.index + 1}"}
                    </span>
                    <span class="shrink-0 text-xs font-normal text-base-content/40">
                      {Format.short_duration(chapter.end_seconds - chapter.start_seconds)}
                    </span>
                  </span>
                  <span class="shrink-0 tabular-nums text-base-content/50">
                    {Format.clock(chapter.start_seconds)}
                  </span>
                </button>
              </li>
            </ul>
          </div>
        </div>
      <% end %>

      <%= if @show_bookmarks and @book do %>
        <div
          id="player-bookmarks-modal"
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
          phx-window-keydown="close_bookmarks"
          phx-key="escape"
        >
          <div class="absolute inset-0 bg-black/50" phx-click="close_bookmarks" aria-hidden="true">
          </div>

          <div
            role="dialog"
            aria-modal="true"
            aria-labelledby="player-bookmarks-title"
            class="relative flex max-h-[80vh] w-full max-w-lg flex-col overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-2xl"
          >
            <div class="flex items-center justify-between border-b border-base-300 px-5 py-4">
              <h2 id="player-bookmarks-title" class="text-lg font-semibold">Your Bookmarks</h2>
              <button
                type="button"
                phx-click="close_bookmarks"
                aria-label="Close"
                class="flex size-8 items-center justify-center rounded-full text-base-content/60 hover:bg-base-200 hover:text-base-content transition"
              >
                <.icon name="hero-x-mark" class="size-5" />
              </button>
            </div>

            <div class="overflow-y-auto">
              <ul class="divide-y divide-base-200">
                <li
                  :for={bookmark <- @bookmarks}
                  class="group flex items-center gap-3 px-5 py-3 text-sm hover:bg-base-200 transition"
                >
                  <button
                    type="button"
                    phx-click="play_bookmark"
                    phx-value-position={bookmark.position_seconds}
                    class="flex min-w-0 flex-1 items-center gap-3 text-left"
                    title="Jump to bookmark"
                  >
                    <span class="shrink-0 tabular-nums font-medium text-primary">
                      {Format.clock(bookmark.position_seconds)}
                    </span>
                    <span class="truncate text-base-content/80">
                      {bookmark.note || "Bookmark"}
                    </span>
                  </button>
                  <button
                    type="button"
                    phx-click="delete_bookmark"
                    phx-value-id={bookmark.id}
                    aria-label="Delete bookmark"
                    title="Delete bookmark"
                    class="flex size-7 shrink-0 items-center justify-center rounded-full text-base-content/40 hover:bg-error/10 hover:text-error transition"
                  >
                    <.icon name="hero-trash" class="size-4" />
                  </button>
                </li>
                <li
                  :if={@bookmarks == []}
                  class="px-5 py-4 text-sm text-base-content/50"
                >
                  No bookmarks yet. Add one at the current position below.
                </li>
              </ul>

              <form
                phx-submit="add_bookmark"
                class="flex items-center gap-2 border-t border-base-300 px-5 py-4"
              >
                <span class="shrink-0 tabular-nums font-medium text-base-content/60">
                  {Format.clock(@position)}
                </span>
                <input
                  type="text"
                  name="note"
                  placeholder="Note (optional)"
                  maxlength="500"
                  autocomplete="off"
                  class="min-w-0 flex-1 rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm focus:border-primary focus:outline-none"
                />
                <button
                  type="submit"
                  aria-label="Add bookmark at current position"
                  class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-primary text-primary-content hover:opacity-90 transition"
                >
                  <.icon name="hero-plus" class="size-5" />
                </button>
              </form>
            </div>
          </div>
        </div>
      <% end %>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Scrubber">
        export default {
          mounted() {
            this.el.addEventListener("click", (e) => {
              const rect = this.el.getBoundingClientRect()
              const ratio = Math.min(Math.max((e.clientX - rect.left) / rect.width, 0), 1)
              // The bar represents the current chapter; let the AudioPlayer hook
              // convert the ratio to an absolute time using its chapter data.
              document.getElementById("player").dispatchEvent(
                new CustomEvent("player:seek-chapter", { detail: { ratio } })
              )
            })
          }
        }
      </script>
    </div>
    """
  end
end
