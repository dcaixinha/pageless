defmodule PagelessWeb.SettingsLive.ListeningSessions do
  use PagelessWeb, :live_view

  alias Pageless.Accounts
  alias Pageless.Accounts.User
  alias Pageless.Format
  alias Pageless.Playback

  @per_page_options [10, 25, 50]

  @impl true
  def mount(_params, _session, socket) do
    settings = Accounts.get_player_settings(socket.assigns.current_scope.user)

    {:ok,
     socket
     |> assign(page_title: "Listening Sessions")
     |> assign(date_format: settings.date_format, time_format: settings.time_format)
     |> assign(page: 1, per_page: 10, user_id: "", selected_session: nil)
     |> assign(per_page_options: @per_page_options)
     |> assign(users: Accounts.list_users(socket.assigns.current_scope))
     |> assign_sessions()}
  end

  @impl true
  def handle_event("filter", %{"user_id" => user_id}, socket) do
    {:noreply, socket |> assign(user_id: user_id, page: 1) |> assign_sessions()}
  end

  def handle_event("per_page", %{"per_page" => per_page}, socket) do
    {:noreply, socket |> assign(per_page: parse_per_page(per_page), page: 1) |> assign_sessions()}
  end

  def handle_event("page", %{"direction" => "prev"}, socket) do
    {:noreply, socket |> assign(page: max(socket.assigns.page - 1, 1)) |> assign_sessions()}
  end

  def handle_event("page", %{"direction" => "next"}, socket) do
    {:noreply,
     socket
     |> assign(page: min(socket.assigns.page + 1, socket.assigns.total_pages))
     |> assign_sessions()}
  end

  def handle_event("show", %{"id" => id}, socket) do
    {:noreply,
     assign(socket,
       selected_session: Playback.get_listening_session!(socket.assigns.current_scope, id)
     )}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, selected_session: nil)}
  end

  def handle_event("delete", _params, %{assigns: %{selected_session: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("delete", _params, socket) do
    {:ok, _session} =
      Playback.delete_listening_session(
        socket.assigns.current_scope,
        socket.assigns.selected_session
      )

    {:noreply,
     socket
     |> put_flash(:info, "Listening session deleted.")
     |> assign(selected_session: nil)
     |> assign_sessions()}
  end

  defp assign_sessions(socket) do
    opts = [
      page: socket.assigns.page,
      per_page: socket.assigns.per_page,
      user_id: socket.assigns.user_id
    ]

    total = Playback.count_listening_sessions(socket.assigns.current_scope, opts)
    total_pages = max(ceil(total / socket.assigns.per_page), 1)
    page = min(socket.assigns.page, total_pages)
    opts = Keyword.put(opts, :page, page)

    assign(socket,
      page: page,
      total: total,
      total_pages: total_pages,
      sessions: Playback.list_listening_sessions(socket.assigns.current_scope, opts)
    )
  end

  defp parse_per_page(value) do
    value = String.to_integer(value || "10")
    if value in @per_page_options, do: value, else: 10
  end

  defp user_name(%User{} = user), do: User.display_name(user)
  defp user_name(_), do: "Unknown"

  defp item_title(session),
    do: session.title || (session.book && session.book.title) || "Unknown item"

  defp item_author(session), do: session.authors || format_authors(session.book) || ""
  defp format_authors(nil), do: nil
  defp format_authors(book), do: Enum.map_join(book.authors || [], ", ", & &1.name)

  defp device_lines(device_info) do
    device_info
    |> to_string()
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
  end

  defp last_update(nil), do: "Unknown"

  defp last_update(%DateTime{} = datetime) do
    diff = DateTime.diff(DateTime.utc_now(:second), datetime, :second)

    cond do
      diff < 60 -> "less than a minute ago"
      diff < 3600 -> "#{div(diff, 60)} min ago"
      diff < 86_400 -> "about #{div(diff, 3600)} hours ago"
      true -> "#{div(diff, 86_400)} days ago"
    end
  end

  defp exact_datetime(nil, _date_format, _time_format), do: nil

  defp exact_datetime(%DateTime{} = datetime, date_format, time_format),
    do: Format.datetime(datetime, date_format, time_format, seconds: true) <> " UTC"

  defp event_label(event), do: event.event || "Event"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} socket={@socket} active={:settings}>
      <Layouts.settings_shell active={:listening_sessions}>
        <div class="space-y-6">
          <div class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h1 class="text-3xl font-bold tracking-tight">Listening Sessions</h1>
              <p class="mt-1 text-sm text-base-content/60">
                Review playback sessions captured by web and mobile clients.
              </p>
            </div>

            <form id="session-user-filter" phx-change="filter" class="w-full sm:w-56">
              <label
                class="text-xs font-semibold text-base-content/70"
                for="session-user-filter-select"
              >
                Filter by user
              </label>
              <select
                id="session-user-filter-select"
                name="user_id"
                class="mt-1 w-full rounded-xl border border-[color:var(--pg-border)] bg-[color:var(--pg-surface)] px-3 py-2 text-sm focus:border-primary focus:outline-none"
              >
                <option value="" selected={@user_id == ""}>All Users</option>
                <option :for={user <- @users} value={user.id} selected={@user_id == user.id}>
                  {user_name(user)}
                </option>
              </select>
            </form>
          </div>

          <section class="overflow-hidden rounded-2xl border border-[color:var(--pg-border)] bg-[color:var(--pg-surface)] shadow-sm">
            <div :if={@sessions == []} class="p-10 text-center text-sm text-base-content/60">
              No listening sessions yet.
            </div>

            <div :if={@sessions != []}>
              <table class="w-full table-fixed text-left text-sm">
                <thead class="bg-[color:var(--pg-tab)] text-xs font-semibold text-[color:var(--pg-muted)]">
                  <tr>
                    <th class="w-[22%] px-4 py-3">Item</th>
                    <th class="w-[14%] px-4 py-3">User</th>
                    <th class="w-[12%] px-4 py-3">Play Method</th>
                    <th class="w-[24%] px-4 py-3">Device Info</th>
                    <th class="w-[10%] px-4 py-3 text-right">Time Listened</th>
                    <th class="w-[9%] px-4 py-3 text-right">Last Time</th>
                    <th class="w-[9%] px-4 py-3 text-right">Last Update</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-[color:var(--pg-border)]">
                  <tr
                    :for={session <- @sessions}
                    id={"listening-session-#{session.id}"}
                    phx-click="show"
                    phx-value-id={session.id}
                    class="cursor-pointer hover:bg-[color:var(--pg-tab-active)]"
                  >
                    <td class="px-4 py-3">
                      <div class="truncate font-medium">{item_title(session)}</div>
                      <div class="truncate text-xs text-[color:var(--pg-muted)]">
                        {item_author(session)}
                      </div>
                    </td>
                    <td class="truncate px-4 py-3">{user_name(session.user)}</td>
                    <td class="truncate px-4 py-3">{session.play_method}</td>
                    <td class="px-4 py-3 text-xs" title={session.device_info}>
                      <div :for={line <- device_lines(session.device_info)} class="truncate">
                        {line}
                      </div>
                    </td>
                    <td class="px-4 py-3 text-right font-mono text-xs">
                      {Format.short_duration(session.time_listened_seconds)}
                    </td>
                    <td class="px-4 py-3 text-right font-mono text-xs">
                      {Format.clock(session.last_position_seconds)}
                    </td>
                    <td
                      class="px-4 py-3 text-right text-xs"
                      title={exact_datetime(session.updated_at_client, @date_format, @time_format)}
                    >
                      {last_update(session.updated_at_client)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>

          <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-end">
            <form id="sessions-per-page" phx-change="per_page" class="flex items-center gap-2">
              <label for="sessions-per-page-select" class="text-sm text-base-content/70">Rows per page</label>
              <select
                id="sessions-per-page-select"
                name="per_page"
                class="rounded-xl border border-[color:var(--pg-border)] bg-[color:var(--pg-surface)] px-3 py-2 text-sm focus:border-primary focus:outline-none"
              >
                <option :for={n <- @per_page_options} value={n} selected={@per_page == n}>{n}</option>
              </select>
            </form>

            <div class="flex items-center justify-end gap-2">
              <span class="text-sm text-base-content/70">Page {@page} of {@total_pages}</span>
              <button
                type="button"
                phx-click="page"
                phx-value-direction="prev"
                disabled={@page <= 1}
                class="rounded-xl border border-[color:var(--pg-border)] px-3 py-2 disabled:opacity-40"
              >
                <.icon name="hero-chevron-left" class="size-4" />
              </button>
              <button
                type="button"
                phx-click="page"
                phx-value-direction="next"
                disabled={@page >= @total_pages}
                class="rounded-xl border border-[color:var(--pg-border)] px-3 py-2 disabled:opacity-40"
              >
                <.icon name="hero-chevron-right" class="size-4" />
              </button>
            </div>
          </div>
        </div>
      </Layouts.settings_shell>

      <.session_modal
        :if={@selected_session}
        session={@selected_session}
        date_format={@date_format}
        time_format={@time_format}
      />
    </Layouts.app>
    """
  end

  attr :session, :map, required: true
  attr :date_format, :string, required: true
  attr :time_format, :string, required: true

  defp session_modal(assigns) do
    ~H"""
    <div
      id="listening-session-modal"
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      phx-window-keydown="close_modal"
      phx-key="escape"
    >
      <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" phx-click="close_modal" />
      <div class="relative max-h-[90vh] w-full max-w-3xl overflow-y-auto rounded-2xl border border-[color:var(--pg-border)] bg-[color:var(--pg-surface)] p-5 shadow-2xl">
        <div class="flex items-start justify-between gap-4">
          <div class="min-w-0">
            <h2 class="truncate text-xl font-bold">{item_title(@session)}</h2>
            <p class="mt-1 truncate text-sm text-[color:var(--pg-muted)]">{item_author(@session)}</p>
          </div>
          <button
            type="button"
            phx-click="close_modal"
            aria-label="Close"
            class="rounded-full p-2 text-base-content/60 transition hover:bg-[color:var(--pg-tab-active)] hover:text-base-content"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <dl class="mt-5 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <div>
            <dt class="text-xs font-semibold uppercase tracking-wide text-[color:var(--pg-muted)]">
              User
            </dt>
            <dd class="mt-1">{user_name(@session.user)}</dd>
          </div>
          <div>
            <dt class="text-xs font-semibold uppercase tracking-wide text-[color:var(--pg-muted)]">
              Play Method
            </dt>
            <dd class="mt-1">{@session.play_method}</dd>
          </div>
          <div>
            <dt class="text-xs font-semibold uppercase tracking-wide text-[color:var(--pg-muted)]">
              Time Listened
            </dt>
            <dd class="mt-1 font-mono">{Format.short_duration(@session.time_listened_seconds)}</dd>
          </div>
          <div>
            <dt class="text-xs font-semibold uppercase tracking-wide text-[color:var(--pg-muted)]">
              Last Time
            </dt>
            <dd class="mt-1 font-mono">{Format.clock(@session.last_position_seconds)}</dd>
          </div>
          <div>
            <dt class="text-xs font-semibold uppercase tracking-wide text-[color:var(--pg-muted)]">
              Started
            </dt>
            <dd class="mt-1">{exact_datetime(@session.started_at, @date_format, @time_format)}</dd>
          </div>
          <div>
            <dt class="text-xs font-semibold uppercase tracking-wide text-[color:var(--pg-muted)]">
              Last Update
            </dt>
            <dd class="mt-1">
              {exact_datetime(@session.updated_at_client, @date_format, @time_format)}
            </dd>
          </div>
        </dl>

        <div class="mt-5 rounded-xl border border-[color:var(--pg-border)] bg-[color:var(--pg-surface-raised)] p-4">
          <h3 class="text-sm font-semibold">Device Info</h3>
          <div class="mt-2 space-y-1 text-sm text-[color:var(--pg-muted)]">
            <div :for={line <- device_lines(@session.device_info)}>{line}</div>
          </div>
        </div>

        <div class="mt-5">
          <h3 class="text-sm font-semibold">Events ({length(@session.events || [])})</h3>
          <div
            :if={@session.events == []}
            class="mt-2 rounded-xl border border-dashed border-[color:var(--pg-border)] p-4 text-sm text-base-content/60"
          >
            No events recorded for this session.
          </div>
          <ul
            :if={@session.events != []}
            class="mt-2 overflow-hidden rounded-xl border border-[color:var(--pg-border)] text-sm"
          >
            <li
              :for={event <- @session.events}
              class="grid grid-cols-[1fr_auto_auto] gap-4 border-b border-[color:var(--pg-border)] px-4 py-2 last:border-b-0"
            >
              <span>{event_label(event)}</span>
              <span class="font-mono text-xs text-[color:var(--pg-muted)]">{Format.clock(
                event.position_seconds
              )}</span>
              <span class="text-xs text-[color:var(--pg-muted)]">
                {exact_datetime(event.occurred_at, @date_format, @time_format)}
              </span>
            </li>
          </ul>
        </div>

        <div class="mt-6 flex justify-end gap-2 border-t border-[color:var(--pg-border)] pt-4">
          <button
            type="button"
            phx-click="delete"
            data-confirm="Delete this listening session?"
            class="rounded-xl bg-error px-4 py-2 text-sm font-semibold text-error-content transition hover:opacity-90"
          >
            Delete session
          </button>
        </div>
      </div>
    </div>
    """
  end
end
