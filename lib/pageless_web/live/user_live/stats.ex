defmodule PagelessWeb.UserLive.Stats do
  use PagelessWeb, :live_view

  alias Pageless.{Accounts, Format, Library, Playback}
  alias Pageless.Library.Events

  @impl true
  def mount(_params, _session, socket) do
    review_year = Date.utc_today().year - 1
    settings = Accounts.get_player_settings(socket.assigns.current_scope.user)

    if connected?(socket), do: Events.subscribe(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(page_title: "Your Stats")
     |> assign(stats_section: :stats)
     |> assign(date_format: settings.date_format, time_format: settings.time_format)
     |> assign(
       review_year: review_year,
       min_review_year: review_year - 5,
       max_review_year: Date.utc_today().year
     )
     |> assign(stats: Playback.user_stats(socket.assigns.current_scope))
     |> assign(library_stats: Library.library_stats(socket.assigns.current_scope))
     |> assign_year_review(review_year)}
  end

  @impl true
  def handle_info({:catalog_changed, _changes}, socket) do
    {:noreply,
     socket
     |> assign(stats: Playback.user_stats(socket.assigns.current_scope))
     |> assign(library_stats: Library.library_stats(socket.assigns.current_scope))
     |> assign_year_review(socket.assigns.review_year)}
  end

  @impl true
  def handle_event("stats_section", %{"section" => "review"}, socket) do
    {:noreply, assign(socket, stats_section: :review)}
  end

  def handle_event("stats_section", %{"section" => "stats"}, socket) do
    {:noreply, assign(socket, stats_section: :stats)}
  end

  def handle_event("stats_section", %{"section" => "library"}, socket) do
    {:noreply, assign(socket, stats_section: :library)}
  end

  def handle_event("review_year", %{"direction" => "prev"}, socket) do
    year = max(socket.assigns.review_year - 1, socket.assigns.min_review_year)
    {:noreply, assign_year_review(socket, year)}
  end

  def handle_event("review_year", %{"direction" => "next"}, socket) do
    year = min(socket.assigns.review_year + 1, socket.assigns.max_review_year)
    {:noreply, assign_year_review(socket, year)}
  end

  defp assign_year_review(socket, year) do
    socket
    |> assign(review_year: year)
    |> assign(year_review: Playback.user_year_review(socket.assigns.current_scope, year))
    |> assign(server_year_review: Library.server_year_review(year))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} socket={@socket} active={:stats}>
      <div class="mx-auto max-w-5xl space-y-8">
        <div class="inline-flex overflow-hidden rounded-2xl border border-[color:var(--pg-border)] bg-[color:var(--pg-surface)] p-1 shadow-sm">
          <button
            type="button"
            phx-click="stats_section"
            phx-value-section="stats"
            class={[
              "rounded-xl px-5 py-2.5 text-sm font-semibold transition",
              if(@stats_section == :stats,
                do: "bg-primary text-primary-content shadow-sm",
                else:
                  "text-base-content/70 hover:bg-[color:var(--pg-tab-active)] hover:text-base-content"
              )
            ]}
          >
            Your Stats
          </button>
          <button
            type="button"
            phx-click="stats_section"
            phx-value-section="library"
            class={[
              "rounded-xl px-5 py-2.5 text-sm font-semibold transition",
              if(@stats_section == :library,
                do: "bg-primary text-primary-content shadow-sm",
                else:
                  "text-base-content/70 hover:bg-[color:var(--pg-tab-active)] hover:text-base-content"
              )
            ]}
          >
            Library Stats
          </button>
          <button
            type="button"
            phx-click="stats_section"
            phx-value-section="review"
            class={[
              "rounded-xl px-5 py-2.5 text-sm font-semibold transition",
              if(@stats_section == :review,
                do: "bg-primary text-primary-content shadow-sm",
                else:
                  "text-base-content/70 hover:bg-[color:var(--pg-tab-active)] hover:text-base-content"
              )
            ]}
          >
            Year in Review
          </button>
        </div>

        <section
          :if={@stats_section == :review}
          class="rounded-2xl border border-[color:var(--pg-border)] bg-[color:var(--pg-surface)] p-5 shadow-sm"
        >
          <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
            <h1 class="text-3xl font-bold tracking-tight">Year in Review</h1>
            <div class="inline-flex w-fit items-center overflow-hidden rounded-xl border border-[color:var(--pg-border)] bg-[color:var(--pg-tab)]">
              <button
                type="button"
                phx-click="review_year"
                phx-value-direction="prev"
                disabled={@review_year <= @min_review_year}
                class="flex size-10 items-center justify-center transition hover:bg-[color:var(--pg-tab-active)] disabled:cursor-not-allowed disabled:opacity-40"
                aria-label="Previous year"
              >
                <.icon name="hero-chevron-left" class="size-5" />
              </button>
              <div class="min-w-20 px-4 text-center text-lg font-bold tabular-nums">
                {@review_year}
              </div>
              <button
                type="button"
                phx-click="review_year"
                phx-value-direction="next"
                disabled={@review_year >= @max_review_year}
                class="flex size-10 items-center justify-center transition hover:bg-[color:var(--pg-tab-active)] disabled:cursor-not-allowed disabled:opacity-40"
                aria-label="Next year"
              >
                <.icon name="hero-chevron-right" class="size-5" />
              </button>
            </div>
          </div>

          <div class="mt-6 space-y-8 border-t border-[color:var(--pg-border)] pt-6">
            <.year_review_card review={@year_review} title="Your Year in Review" />
            <.server_review_card
              :if={Pageless.Accounts.User.admin?(@current_scope.user)}
              review={@server_year_review}
            />
          </div>
        </section>

        <section
          :if={@stats_section == :stats}
          class="rounded-2xl border border-[color:var(--pg-border)] bg-[color:var(--pg-surface)] p-6 shadow-sm"
        >
          <h1 class="text-3xl font-bold tracking-tight">Your Stats</h1>

          <div class="mt-8 grid gap-4 sm:grid-cols-3">
            <.stat_card icon="hero-book-open" value={@stats.items_finished} label="Items Finished" />
            <.stat_card icon="hero-calendar-days" value={@stats.days_listened} label="Days Listened" />
            <.stat_card icon="hero-clock" value={@stats.minutes_listening} label="Minutes Listening" />
          </div>

          <div class="mt-10 grid gap-10 lg:grid-cols-[1.2fr_1fr]">
            <div class="space-y-6">
              <h2 class="text-xl font-semibold">Minutes Listening (last 7 days)</h2>
              <.week_chart days={@stats.last_7_days} date_format={@date_format} />
              <div class="grid grid-cols-2 gap-4 sm:grid-cols-4">
                <.small_stat value={@stats.week_minutes} label="Week Listening" unit="minutes" />
                <.small_stat
                  value={@stats.daily_average_minutes}
                  label="Daily Average"
                  unit="minutes"
                />
                <.small_stat value={@stats.best_day_minutes} label="Best Day" unit="minutes" />
                <.small_stat value={@stats.current_streak_days} label="Days" unit="in a row" />
              </div>
            </div>

            <div class="space-y-4">
              <div class="flex items-center justify-between gap-4">
                <h2 class="text-xl font-semibold">Recent Sessions</h2>
                <.link
                  :if={Pageless.Accounts.User.admin?(@current_scope.user)}
                  navigate={~p"/settings/listening-sessions"}
                  class="rounded-lg border border-[color:var(--pg-border)] px-3 py-1.5 text-xs hover:bg-[color:var(--pg-tab-active)]"
                >
                  View All
                </.link>
              </div>
              <ol class="space-y-3">
                <li
                  :for={{session, index} <- Enum.with_index(@stats.recent_sessions, 1)}
                  class="grid grid-cols-[2rem_minmax(0,1fr)_auto] items-center gap-3 text-sm"
                >
                  <span class="text-[color:var(--pg-muted)]">{index}.</span>
                  <div class="min-w-0">
                    <div class="truncate">{session.title || "Unknown item"}</div>
                    <div class="text-xs text-[color:var(--pg-muted)]">
                      {last_update(session.updated_at_client)}
                    </div>
                  </div>
                  <span class="font-semibold">{Format.short_duration(session.time_listened_seconds)}</span>
                </li>
              </ol>
              <div
                :if={@stats.recent_sessions == []}
                class="rounded-xl border border-dashed border-[color:var(--pg-border)] p-6 text-sm text-base-content/60"
              >
                No sessions yet.
              </div>
            </div>
          </div>

          <div class="mt-10 space-y-3">
            <h2 class="text-sm text-base-content/70">
              {length(Enum.filter(@stats.year_days, &(&1.minutes > 0)))} days listened in the last year
            </h2>
            <div class="overflow-x-auto rounded-xl border border-[color:var(--pg-border)] bg-[color:var(--pg-tab)] p-4">
              <div class="grid w-max grid-flow-col grid-rows-7 gap-1">
                <div :for={day <- @stats.year_days} class="group relative size-3">
                  <div
                    class="size-3 rounded-sm bg-primary"
                    style={"opacity: #{heat_opacity(day.minutes)}"}
                  >
                  </div>
                  <.chart_tooltip>{heat_title(day, @date_format)}</.chart_tooltip>
                </div>
              </div>

              <div class="mt-4 flex items-center justify-end gap-2 text-xs text-[color:var(--pg-muted)]">
                <span>Less</span>
                <span class="size-3 rounded-sm bg-primary" style="opacity: 0.12"></span>
                <span class="size-3 rounded-sm bg-primary" style="opacity: 0.3"></span>
                <span class="size-3 rounded-sm bg-primary" style="opacity: 0.55"></span>
                <span class="size-3 rounded-sm bg-primary" style="opacity: 0.8"></span>
                <span class="size-3 rounded-sm bg-primary"></span>
                <span>More</span>
              </div>
            </div>
          </div>
        </section>

        <section
          :if={@stats_section == :library}
          class="rounded-2xl border border-[color:var(--pg-border)] bg-[color:var(--pg-surface)] p-6 shadow-sm"
        >
          <div>
            <h1 class="text-3xl font-bold tracking-tight">Library Stats</h1>
            <p class="mt-1 text-sm text-base-content/60">
              A high-level overview of the audiobooks available to your account.
            </p>
          </div>

          <section class="mt-8 grid gap-4 sm:grid-cols-2 xl:grid-cols-5">
            <.library_stat_card
              icon="hero-rectangle-stack"
              value={format_int(@library_stats.total_items)}
              label="Items in Library"
            />
            <.library_stat_card
              icon="hero-chart-bar"
              value={format_hours(@library_stats.total_hours)}
              label="Overall Hours"
            />
            <.library_stat_card
              icon="hero-user"
              value={format_int(@library_stats.total_authors)}
              label="Authors"
            />
            <.library_stat_card
              icon="hero-document"
              value={format_gb(@library_stats.total_size_bytes)}
              label="Size (GB)"
            />
            <.library_stat_card
              icon="hero-musical-note"
              value={format_int(@library_stats.audio_tracks)}
              label="Audio Tracks"
            />
          </section>

          <section class="mt-10 grid gap-10 lg:grid-cols-2">
            <.ranked_panel
              title="Top Genres"
              items={@library_stats.top_genres}
              value_fun={&format_int(&1.count)}
              max_value={max_count(@library_stats.top_genres)}
            />
            <.ranked_panel
              title="Top Authors"
              items={@library_stats.top_authors}
              value_fun={&format_int(&1.count)}
              max_value={max_count(@library_stats.top_authors)}
            />
            <.ranked_panel
              title="Longest Items"
              items={@library_stats.longest_items}
              value_fun={&Format.duration(&1.value)}
              max_value={max_value(@library_stats.longest_items)}
            />
            <.ranked_panel
              title="Largest Items"
              items={@library_stats.largest_items}
              value_fun={&format_gb(&1.value)}
              max_value={max_value(@library_stats.largest_items)}
            />
          </section>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :review, :map, required: true
  attr :title, :string, required: true

  defp year_review_card(assigns) do
    ~H"""
    <div class="relative overflow-hidden rounded-2xl border border-[color:var(--pg-border)] bg-[color:var(--pg-tab)] p-6">
      <.review_cover_collage books={@review.cover_books} />
      <div class="relative z-10">
        <div class="pg-brand-wordmark text-lg font-bold text-primary">
          Pageless {@review.year} Year in Review
        </div>
        <h3 class="mt-6 text-center text-lg font-semibold">{@title}</h3>

        <div class="mt-4 grid gap-4 sm:grid-cols-2">
          <.review_metric
            icon="hero-check-badge"
            value={@review.books_finished}
            label="books finished"
          />
          <.review_metric
            icon="hero-clock"
            value={format_duration(@review.seconds_listening)}
            label="spent listening"
          />
          <.review_metric icon="hero-signal" value={@review.sessions_count} label="sessions" />
          <.review_metric
            icon="hero-book-open"
            value={@review.books_listened}
            label="books listened to"
          />
        </div>

        <div class="mt-8 grid gap-6 sm:grid-cols-2">
          <.review_top title="Top Author" item={@review.top_author} />
          <.review_top title="Top Genre" item={@review.top_genre} />
          <.review_top title="Top Month" item={@review.top_month} />
        </div>
      </div>
    </div>
    """
  end

  attr :review, :map, required: true

  defp server_review_card(assigns) do
    ~H"""
    <div class="relative overflow-hidden rounded-2xl border border-[color:var(--pg-border)] bg-[color:var(--pg-tab)] p-6">
      <.review_cover_collage books={@review.cover_books} />
      <div class="relative z-10">
        <div class="pg-brand-wordmark text-lg font-bold text-primary">
          Pageless {@review.year} Server Review
        </div>
        <div class="mt-6 grid gap-4 sm:grid-cols-3">
          <.review_metric icon="hero-book-open" value={@review.books_added} label="books added" />
          <.review_metric icon="hero-user" value={@review.authors_added} label="authors added" />
          <.review_metric icon="hero-chart-bar" value={@review.sessions_count} label="sessions" />
        </div>

        <div class="mt-8 space-y-6 text-center">
          <div>
            <div class="text-primary">Your book collection grew by...</div>
            <div class="mt-1 text-3xl font-bold">{format_gb(@review.size_added_bytes)} GB</div>
          </div>
          <div>
            <div class="text-primary">With a total duration of...</div>
            <div class="mt-1 text-3xl font-bold">
              {format_duration(@review.duration_added_seconds)}
            </div>
          </div>
        </div>

        <div :if={@review.additions != []} class="mt-8">
          <div class="text-center text-primary">Some additions include...</div>
          <div class="mt-4 flex justify-center gap-2 overflow-hidden">
            <img
              :for={book <- @review.additions}
              src={~p"/books/#{book.id}/cover"}
              alt={book.title}
              class="size-24 rounded-lg object-cover"
              onerror="this.style.visibility='hidden'"
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :books, :list, required: true

  defp review_cover_collage(assigns) do
    assigns = assign(assigns, cover_books: repeat_cover_books(assigns.books, 24))

    ~H"""
    <div :if={@cover_books != []} class="pointer-events-none absolute inset-0 opacity-30">
      <div class="absolute -inset-14 grid rotate-[-10deg] grid-cols-4 gap-3 sm:grid-cols-6">
        <img
          :for={book <- @cover_books}
          src={~p"/books/#{book.id}/cover"}
          alt=""
          class="aspect-square w-full rounded-xl object-cover grayscale-[35%]"
          onerror="this.style.visibility='hidden'"
        />
      </div>
      <div class="absolute inset-0 bg-gradient-to-br from-[color:var(--pg-surface)]/95 via-primary/35 to-amber-900/55">
      </div>
    </div>
    """
  end

  defp repeat_cover_books([], _count), do: []

  defp repeat_cover_books(books, count) do
    books
    |> Stream.cycle()
    |> Enum.take(count)
  end

  attr :icon, :string, required: true
  attr :value, :any, required: true
  attr :label, :string, required: true

  defp review_metric(assigns) do
    ~H"""
    <div class="rounded-2xl border border-white/20 bg-white/10 p-5 text-center">
      <.icon name={@icon} class="mx-auto size-9 text-primary" />
      <div class="mt-2 text-4xl font-bold">{@value}</div>
      <div class="text-lg text-primary">{@label}</div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :item, :map, default: nil

  defp review_top(assigns) do
    ~H"""
    <div :if={@item}>
      <div class="text-sm font-semibold uppercase tracking-wide text-primary">{@title}</div>
      <div class="mt-1 truncate text-2xl font-bold">{Map.get(@item, :name)}</div>
      <div class="text-[color:var(--pg-muted)]">{format_duration(Map.get(@item, :seconds, 0))}</div>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :value, :integer, required: true
  attr :label, :string, required: true

  defp stat_card(assigns) do
    ~H"""
    <div class="flex items-center justify-center gap-3 text-center">
      <.icon name={@icon} class="size-11 text-primary" />
      <div>
        <div class="text-4xl font-bold leading-none">{@value}</div>
        <div class="mt-1 text-sm text-[color:var(--pg-muted)]">{@label}</div>
      </div>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true

  defp library_stat_card(assigns) do
    ~H"""
    <div class="rounded-2xl border border-[color:var(--pg-border)] bg-[color:var(--pg-tab)] p-4 shadow-sm">
      <div class="flex h-full items-center justify-center gap-3 text-center">
        <.icon name={@icon} class="size-8 text-primary" />
        <div class="min-w-0">
          <div class="text-3xl font-bold leading-none">{@value}</div>
          <div class="mt-1 text-sm text-[color:var(--pg-muted)]">{@label}</div>
        </div>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :items, :list, required: true
  attr :value_fun, :any, required: true
  attr :max_value, :float, required: true

  defp ranked_panel(assigns) do
    ~H"""
    <div class="space-y-4">
      <h2 class="text-xl font-semibold">{@title}</h2>
      <div
        :if={@items == []}
        class="rounded-xl border border-dashed border-[color:var(--pg-border)] p-6 text-sm text-base-content/60"
      >
        No data yet.
      </div>
      <ol class="space-y-3">
        <li
          :for={{item, index} <- Enum.with_index(@items, 1)}
          class="grid grid-cols-[2rem_minmax(0,1fr)_8rem_auto] items-center gap-3 text-sm"
        >
          <span class="text-[color:var(--pg-muted)]">{index}.</span>
          <span class="truncate">{item_label(item)}</span>
          <div class="h-2 overflow-hidden rounded-full bg-[color:var(--pg-tab)]">
            <div
              class="h-full rounded-full bg-primary"
              style={"width: #{bar_width(item_value(item), @max_value)}%"}
            >
            </div>
          </div>
          <span class="font-semibold tabular-nums">{@value_fun.(item)}</span>
        </li>
      </ol>
    </div>
    """
  end

  attr :value, :integer, required: true
  attr :label, :string, required: true
  attr :unit, :string, required: true

  defp small_stat(assigns) do
    ~H"""
    <div class="text-center">
      <div class="text-xs text-base-content/70">{@label}</div>
      <div class="text-3xl font-bold leading-none">{@value}</div>
      <div class="text-sm text-[color:var(--pg-muted)]">{@unit}</div>
    </div>
    """
  end

  attr :days, :list, required: true
  attr :date_format, :string, required: true

  defp week_chart(assigns) do
    max_minutes = assigns.days |> Enum.map(& &1.minutes) |> Enum.max(fn -> 0 end) |> max(1)
    mid_minutes = div(max_minutes, 2)

    assigns = assign(assigns, max_minutes: max_minutes, mid_minutes: mid_minutes)

    ~H"""
    <div class="h-72 rounded-xl border border-[color:var(--pg-border)] bg-[color:var(--pg-tab)] p-4">
      <div class="grid h-56 grid-cols-[3rem_minmax(0,1fr)] gap-3">
        <div class="grid h-48 grid-rows-[auto_1fr_auto_1fr_auto] pb-2 text-right text-xs text-[color:var(--pg-muted)]">
          <span>{@max_minutes}</span>
          <span></span>
          <span>{@mid_minutes}</span>
          <span></span>
          <span>0</span>
        </div>

        <div class="relative h-56">
          <div class="absolute inset-x-0 top-0 border-t border-[color:var(--pg-border)]"></div>
          <div class="absolute inset-x-0 top-24 border-t border-[color:var(--pg-border)]"></div>
          <div class="absolute inset-x-0 top-48 border-t border-[color:var(--pg-border)]"></div>

          <div class="relative flex h-56 items-start gap-3">
            <div :for={day <- @days} class="flex min-w-0 flex-1 flex-col items-center gap-2">
              <div class="flex h-48 w-full items-end justify-center pb-2">
                <div class="group relative flex h-full items-end justify-center">
                  <div
                    class="w-3 rounded-full bg-primary"
                    style={"height: #{bar_height(day.minutes, @max_minutes)}%"}
                  >
                  </div>
                  <.chart_tooltip>{heat_title(day, @date_format)}</.chart_tooltip>
                </div>
              </div>
              <span class="text-xs text-[color:var(--pg-muted)]">{day.label}</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  slot :inner_block, required: true

  defp chart_tooltip(assigns) do
    ~H"""
    <div class="pointer-events-none absolute left-1/2 top-full z-50 mt-2 hidden -translate-x-1/2 whitespace-nowrap rounded-lg bg-primary px-3 py-2 text-xs font-medium text-primary-content shadow-xl group-hover:block">
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp heat_opacity(0), do: 0.12
  defp heat_opacity(minutes) when minutes < 15, do: 0.3
  defp heat_opacity(minutes) when minutes < 60, do: 0.55
  defp heat_opacity(_minutes), do: 1.0

  defp bar_height(0, _max), do: 0
  defp bar_height(minutes, max_minutes), do: max(minutes / max_minutes * 100, 4)

  defp heat_title(%{date: date, minutes: 0}, date_format),
    do: "No listening on #{Format.date(date, date_format)}"

  defp heat_title(%{date: date, minutes: minutes}, date_format) do
    "#{Format.duration(minutes * 60)} listening on #{Format.date(date, date_format)}"
  end

  defp max_count([]), do: 0.0
  defp max_count(items), do: items |> Enum.map(&to_number(&1.count)) |> Enum.max()
  defp max_value([]), do: 0.0

  defp max_value(items),
    do: items |> Enum.map(&(Map.get(&1, :value) |> to_number())) |> Enum.max()

  defp item_label(item), do: Map.get(item, :name) || Map.get(item, :title)
  defp item_value(item), do: Map.get(item, :value) || Map.get(item, :count) || 0
  defp bar_width(_value, max) when max <= 0, do: 0
  defp bar_width(value, max), do: to_number(value) / max * 100

  defp format_duration(seconds), do: seconds |> to_number() |> Format.duration()

  defp format_int(value), do: value |> to_number() |> round() |> Integer.to_string()
  defp format_hours(value), do: :erlang.float_to_binary(to_number(value), decimals: 1)

  defp format_gb(bytes),
    do: :erlang.float_to_binary(to_number(bytes) / 1_073_741_824, decimals: 1)

  defp to_number(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp to_number(value) when is_integer(value), do: value * 1.0
  defp to_number(value) when is_float(value), do: value
  defp to_number(_), do: 0.0

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
end
