defmodule Pageless.Playback do
  @moduledoc """
  Tracks per-user listening progress for books.
  """

  import Ecto.Query, warn: false

  alias Pageless.Accounts
  alias Pageless.Accounts.Scope
  alias Pageless.Library.{Book, Genre}
  alias Pageless.Playback.{Bookmark, ListeningEvent, ListeningSession, PlaybackProgress}
  alias Pageless.Repo

  @finished_threshold 0.98

  @doc """
  The fraction of a book's duration that must be reached for it to be
  considered finished. Shared rule between the server and any client that
  reports progress, so both agree on when a book counts as finished.
  """
  def finished_threshold, do: @finished_threshold

  @doc """
  Returns `true` when a playback position counts as "finished" for a book of
  the given duration (i.e. at or past `finished_threshold/0` of the way
  through). Pure, layer-agnostic rule intended to be mirrored by clients.

      iex> Pageless.Playback.finished_at_position?(990, 1000)
      true
      iex> Pageless.Playback.finished_at_position?(500, 1000)
      false
      iex> Pageless.Playback.finished_at_position?(10, 0)
      false
  """
  def finished_at_position?(current_seconds, duration_seconds)
      when is_number(current_seconds) and is_number(duration_seconds) do
    duration_seconds > 0 and current_seconds / duration_seconds >= @finished_threshold
  end

  @doc """
  Returns the progress for the scoped user and book, or nil.
  """
  def get_progress(%Scope{user: user}, book_id) when not is_nil(user) do
    PlaybackProgress
    |> where([p], p.user_id == ^user.id and p.book_id == ^book_id and is_nil(p.deleted_at))
    |> Repo.one()
  end

  @doc """
  Returns the list of book ids the scoped user has any active progress on.
  """
  def book_ids_with_progress(%Scope{user: user}) when not is_nil(user) do
    PlaybackProgress
    |> where([p], p.user_id == ^user.id and is_nil(p.deleted_at))
    |> select([p], p.book_id)
    |> Repo.all()
  end

  @doc """
  Returns a map of `book_id => PlaybackProgress` for the scoped user's active
  progress.
  """
  def progress_by_book(%Scope{user: user}) when not is_nil(user) do
    PlaybackProgress
    |> where([p], p.user_id == ^user.id and is_nil(p.deleted_at))
    |> Repo.all()
    |> Map.new(&{&1.book_id, &1})
  end

  @doc """
  Upserts the listening position for the scoped user and book.

  Automatically marks the book finished when the position is near the end.
  """
  def save_progress(%Scope{user: user}, book_id, current_seconds, duration_seconds)
      when not is_nil(user) do
    now = DateTime.utc_now(:second)
    current = max(current_seconds * 1.0, 0.0)
    duration = max(duration_seconds * 1.0, 0.0)

    finished_at = if finished_at_position?(current, duration), do: now, else: nil

    attrs = %{
      user_id: user.id,
      book_id: book_id,
      current_seconds: current,
      duration_seconds: duration,
      last_played_at: now,
      finished_at: finished_at,
      started_at: now,
      deleted_at: nil,
      inserted_at: now,
      updated_at: now
    }

    Repo.insert_all(
      PlaybackProgress,
      [attrs],
      # Saving revives a tombstoned record (deleted_at -> nil). `started_at` is
      # intentionally omitted from the replace list so it is only set on the
      # first insert and preserved on subsequent updates.
      on_conflict:
        {:replace,
         [
           :current_seconds,
           :duration_seconds,
           :last_played_at,
           :finished_at,
           :deleted_at,
           :updated_at
         ]},
      conflict_target: [:user_id, :book_id]
    )

    get_progress(%Scope{user: user}, book_id)
  end

  @doc """
  Marks a book as finished for the scoped user, creating progress if needed.
  """
  def mark_finished(%Scope{user: user} = scope, book_id, duration_seconds \\ nil)
      when not is_nil(user) do
    now = DateTime.utc_now(:second)
    existing = get_progress(scope, book_id)
    duration = (duration_seconds || (existing && existing.duration_seconds) || 0.0) * 1.0

    attrs = %{
      user_id: user.id,
      book_id: book_id,
      current_seconds: duration,
      duration_seconds: duration,
      last_played_at: now,
      finished_at: now,
      started_at: (existing && existing.started_at) || now,
      deleted_at: nil,
      inserted_at: (existing && existing.inserted_at) || now,
      updated_at: now
    }

    Repo.insert_all(
      PlaybackProgress,
      [attrs],
      on_conflict:
        {:replace,
         [
           :current_seconds,
           :duration_seconds,
           :last_played_at,
           :finished_at,
           :deleted_at,
           :updated_at
         ]},
      conflict_target: [:user_id, :book_id]
    )

    get_progress(scope, book_id)
  end

  @doc """
  Soft-deletes saved progress for the scoped user and book (resets to
  unstarted), keeping a tombstone so the reset propagates to other devices.

  Returns `:ok` regardless of whether a record existed.
  """
  def delete_progress(%Scope{user: user}, book_id) when not is_nil(user) do
    now = DateTime.utc_now(:second)

    PlaybackProgress
    |> where([p], p.user_id == ^user.id and p.book_id == ^book_id and is_nil(p.deleted_at))
    |> Repo.update_all(set: [deleted_at: now, updated_at: now])

    :ok
  end

  @doc """
  Clears the finished state for a book, keeping the existing position.
  """
  def mark_not_finished(%Scope{user: user} = scope, book_id) when not is_nil(user) do
    case get_progress(scope, book_id) do
      nil ->
        nil

      progress ->
        progress
        |> Ecto.Changeset.change(finished_at: nil)
        |> Repo.update!()
    end
  end

  @doc """
  Returns the saved resume position in seconds for a book (0.0 if none).
  """
  def resume_position(scope, book_id) do
    case get_progress(scope, book_id) do
      %PlaybackProgress{current_seconds: secs} -> secs
      _ -> 0.0
    end
  end

  def finished?(%PlaybackProgress{finished_at: nil}), do: false
  def finished?(%PlaybackProgress{}), do: true
  def finished?(_), do: false

  @doc """
  Returns `{book, progress}` tuples for books the user is part-way through
  (started, not finished), most recently played first.
  """
  def continue_listening(%Scope{user: user}, limit \\ 12) when not is_nil(user) do
    query =
      from p in PlaybackProgress,
        join: b in Book,
        on: b.id == p.book_id,
        where:
          p.user_id == ^user.id and is_nil(p.deleted_at) and is_nil(p.finished_at) and
            p.current_seconds > 0.0 and is_nil(b.missing_since),
        where: ^accessible_library_filter(user),
        order_by: [desc: p.last_played_at],
        limit: ^limit,
        preload: [book: [:authors, :series, :publisher, book_narrators: :narrator]]

    query
    |> Repo.all()
    |> Enum.map(&{&1.book, &1})
  end

  @doc """
  Returns `{book, progress}` tuples for books the user has finished, most
  recently finished first.
  """
  def finished_books(%Scope{user: user}, limit \\ 12) when not is_nil(user) do
    query =
      from p in PlaybackProgress,
        join: b in Book,
        on: b.id == p.book_id,
        where:
          p.user_id == ^user.id and is_nil(p.deleted_at) and not is_nil(p.finished_at) and
            is_nil(b.missing_since),
        where: ^accessible_library_filter(user),
        order_by: [desc: p.finished_at],
        limit: ^limit,
        preload: [book: [:authors, :series, :publisher, book_narrators: :narrator]]

    query
    |> Repo.all()
    |> Enum.map(&{&1.book, &1})
  end

  ## Sync (mobile API)

  @doc """
  Optimistically merges a client-supplied progress update using last-write-wins
  by `last_played_at`.

  If no record exists, or the incoming `last_played_at` is newer than the stored
  one, the update is applied; otherwise the server's record wins and is returned
  unchanged. `finished_at` is derived from the winning position via
  `finished_at_position?/2` so the server and client agree on finished state.

  Returns `{:ok, %PlaybackProgress{}}` or `{:error, :not_found}` if the book
  does not exist.
  """
  def upsert_progress(%Scope{user: user}, book_id, attrs) when not is_nil(user) do
    if book_exists?(book_id) do
      current = max(to_float(attrs[:current_seconds]), 0.0)
      duration = max(to_float(attrs[:duration_seconds]), 0.0)
      client_played_at = normalize_datetime(attrs[:last_played_at]) || DateTime.utc_now(:second)
      existing = get_progress(%Scope{user: user}, book_id)

      cond do
        is_nil(existing) ->
          insert_progress(user, book_id, current, duration, client_played_at)

        stale?(client_played_at, existing.last_played_at) ->
          {:ok, existing}

        true ->
          update_progress(existing, current, duration, client_played_at)
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Returns the scoped user's progress records updated at or after `since`
  (a `DateTime`), oldest first. Pass `nil` to return all records.

  Used by clients to pull changes made on other devices/the web.
  """
  def changes_since(%Scope{user: user}, since) when not is_nil(user) do
    PlaybackProgress
    |> where(user_id: ^user.id)
    |> then(fn q -> if since, do: where(q, [p], p.updated_at >= ^since), else: q end)
    |> order_by([p], asc: p.updated_at)
    |> Repo.all()
  end

  @doc """
  Upserts client-captured listening history sessions and events for the scoped user.

  Clients provide stable UUIDs, making the operation idempotent across retries.
  """
  def upsert_listening_history(%Scope{user: user}, sessions, events) when not is_nil(user) do
    Repo.transaction(fn ->
      session_ids =
        sessions
        |> Enum.map(&upsert_listening_session(user, &1))
        |> MapSet.new()

      events
      |> Enum.filter(fn attrs ->
        MapSet.member?(session_ids, attrs["session_id"] || attrs[:session_id])
      end)
      |> Enum.each(&upsert_listening_event(user, &1))

      :ok
    end)
  end

  @doc """
  Lists listening sessions for the admin Settings UI.
  """
  def list_listening_sessions(%Scope{user: user}, opts \\ []) when not is_nil(user) do
    true = Pageless.Accounts.User.admin?(user)

    opts = normalize_session_opts(opts)

    ListeningSession
    |> listening_session_filters(opts)
    |> order_listening_sessions(opts)
    |> limit(^opts.per_page)
    |> offset(^((opts.page - 1) * opts.per_page))
    |> preload([:user, book: :authors])
    |> Repo.all()
  end

  def count_listening_sessions(%Scope{user: user}, opts \\ []) when not is_nil(user) do
    true = Pageless.Accounts.User.admin?(user)

    opts = normalize_session_opts(opts)

    ListeningSession
    |> listening_session_filters(opts)
    |> Repo.aggregate(:count)
  end

  def user_stats(%Scope{user: user}) when not is_nil(user) do
    sessions =
      ListeningSession
      |> where([s], s.user_id == ^user.id)
      |> order_by([s], desc: s.updated_at_client)
      |> Repo.all()

    total_seconds = Enum.reduce(sessions, 0, &(&1.time_listened_seconds + &2))
    listened_dates = listened_dates(sessions)
    last_7_days = last_n_days(7)
    last_7_by_date = seconds_by_date(sessions, MapSet.new(last_7_days))
    year_days = last_n_days(365)
    year_by_date = seconds_by_date(sessions, MapSet.new(year_days))

    %{
      items_finished: finished_count(user),
      days_listened: MapSet.size(listened_dates),
      minutes_listening: div(total_seconds, 60),
      recent_sessions: Enum.take(sessions, 10),
      last_7_days:
        Enum.map(last_7_days, fn date ->
          %{
            date: date,
            label: Calendar.strftime(date, "%a"),
            minutes: div(Map.get(last_7_by_date, date, 0), 60)
          }
        end),
      week_minutes: div(Enum.sum(Map.values(last_7_by_date)), 60),
      daily_average_minutes: daily_average(last_7_by_date),
      best_day_minutes: best_day(last_7_by_date),
      current_streak_days: current_streak(listened_dates),
      year_days:
        Enum.map(year_days, fn date ->
          %{date: date, minutes: div(Map.get(year_by_date, date, 0), 60)}
        end)
    }
  end

  def user_year_review(%Scope{user: user}, year \\ Date.utc_today().year) when not is_nil(user) do
    {start_dt, end_dt} = year_bounds(year)

    sessions =
      ListeningSession
      |> where(
        [s],
        s.user_id == ^user.id and s.started_at >= ^start_dt and s.started_at < ^end_dt
      )
      |> order_by([s], desc: s.time_listened_seconds)
      |> Repo.all()

    total_seconds = Enum.reduce(sessions, 0, &(&1.time_listened_seconds + &2))

    %{
      year: year,
      books_finished: finished_count_for_year(user, start_dt, end_dt),
      seconds_listening: total_seconds,
      sessions_count: length(sessions),
      books_listened: sessions |> Enum.map(& &1.book_id) |> Enum.uniq() |> length(),
      cover_books: year_review_cover_books(user, start_dt, end_dt, 16),
      top_author: top_author_from_sessions(sessions),
      top_genre: top_genre_for_user_year(user, start_dt, end_dt),
      top_month: top_month_from_sessions(sessions)
    }
  end

  def get_listening_session!(%Scope{user: user}, id) when not is_nil(user) do
    true = Pageless.Accounts.User.admin?(user)

    ListeningSession
    |> preload([
      :user,
      book: :authors,
      events: ^from(e in ListeningEvent, order_by: [desc: e.occurred_at])
    ])
    |> Repo.get!(id)
  end

  def delete_listening_session(%Scope{user: user}, %ListeningSession{} = session)
      when not is_nil(user) do
    true = Pageless.Accounts.User.admin?(user)
    Repo.delete(session)
  end

  defp finished_count(user) do
    PlaybackProgress
    |> where([p], p.user_id == ^user.id and is_nil(p.deleted_at) and not is_nil(p.finished_at))
    |> Repo.aggregate(:count)
  end

  defp finished_count_for_year(user, start_dt, end_dt) do
    PlaybackProgress
    |> where(
      [p],
      p.user_id == ^user.id and is_nil(p.deleted_at) and p.finished_at >= ^start_dt and
        p.finished_at < ^end_dt
    )
    |> Repo.aggregate(:count)
  end

  defp top_author_from_sessions(sessions) do
    sessions
    |> Enum.flat_map(fn session ->
      session.authors
      |> to_string()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&{&1, session.time_listened_seconds})
    end)
    |> sum_named_seconds()
  end

  defp year_review_cover_books(user, start_dt, end_dt, limit) do
    session_totals =
      ListeningSession
      |> where(
        [s],
        s.user_id == ^user.id and s.started_at >= ^start_dt and s.started_at < ^end_dt
      )
      |> group_by([s], s.book_id)
      |> order_by([s], desc: sum(s.time_listened_seconds))
      |> limit(^limit)
      |> select([s], %{book_id: s.book_id, seconds: sum(s.time_listened_seconds)})
      |> Repo.all()

    ids = Enum.map(session_totals, & &1.book_id)

    books_by_id =
      Book
      |> where([b], b.id in ^ids and not is_nil(b.cover_path))
      |> preload(:authors)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    session_totals
    |> Enum.map(&Map.get(books_by_id, &1.book_id))
    |> Enum.reject(&is_nil/1)
  end

  defp top_genre_for_user_year(user, start_dt, end_dt) do
    ListeningSession
    |> join(:inner, [s], bg in "books_genres", on: bg.book_id == s.book_id)
    |> join(:inner, [s, bg], g in Genre, on: g.id == bg.genre_id)
    |> where([s], s.user_id == ^user.id and s.started_at >= ^start_dt and s.started_at < ^end_dt)
    |> group_by([s, bg, g], [g.id, g.name])
    |> order_by([s, bg, g], desc: sum(s.time_listened_seconds))
    |> limit(1)
    |> select([s, bg, g], %{name: g.name, seconds: sum(s.time_listened_seconds)})
    |> Repo.one()
  end

  defp top_month_from_sessions(sessions) do
    sessions
    |> Enum.group_by(fn session -> session.started_at.month end)
    |> Enum.map(fn {month, sessions} ->
      %{
        month: month,
        name: month_name(month),
        seconds: Enum.reduce(sessions, 0, &(&1.time_listened_seconds + &2))
      }
    end)
    |> Enum.max_by(& &1.seconds, fn -> nil end)
  end

  defp sum_named_seconds(entries) do
    entries
    |> Enum.reduce(%{}, fn {name, seconds}, acc ->
      Map.update(acc, name, seconds, &(&1 + seconds))
    end)
    |> Enum.map(fn {name, seconds} -> %{name: name, seconds: seconds} end)
    |> Enum.max_by(& &1.seconds, fn -> nil end)
  end

  defp month_name(month) do
    Date.new!(2000, month, 1)
    |> Calendar.strftime("%B")
  end

  defp listened_dates(sessions) do
    sessions
    |> Enum.filter(&(&1.time_listened_seconds > 0))
    |> Enum.map(&session_date/1)
    |> MapSet.new()
  end

  defp seconds_by_date(sessions, allowed_dates) do
    sessions
    |> Enum.filter(&(&1.time_listened_seconds > 0))
    |> Enum.reduce(%{}, fn session, acc ->
      date = session_date(session)

      if MapSet.member?(allowed_dates, date) do
        Map.update(
          acc,
          date,
          session.time_listened_seconds,
          &(&1 + session.time_listened_seconds)
        )
      else
        acc
      end
    end)
  end

  defp session_date(%{started_at: %DateTime{} = datetime}), do: DateTime.to_date(datetime)
  defp session_date(%{updated_at_client: %DateTime{} = datetime}), do: DateTime.to_date(datetime)

  defp last_n_days(n) do
    today = Date.utc_today()
    first = Date.add(today, -(n - 1))
    Date.range(first, today) |> Enum.to_list()
  end

  defp year_bounds(year) do
    start_dt = DateTime.new!(Date.new!(year, 1, 1), ~T[00:00:00], "Etc/UTC")
    end_dt = DateTime.new!(Date.new!(year + 1, 1, 1), ~T[00:00:00], "Etc/UTC")
    {start_dt, end_dt}
  end

  defp daily_average(seconds_by_date) do
    listened_days = Enum.count(seconds_by_date, fn {_date, seconds} -> seconds > 0 end)

    if listened_days == 0 do
      0
    else
      seconds_by_date |> Map.values() |> Enum.sum() |> div(60) |> div(listened_days)
    end
  end

  defp best_day(seconds_by_date),
    do: seconds_by_date |> Map.values() |> Enum.max(fn -> 0 end) |> div(60)

  defp current_streak(listened_dates) do
    today = Date.utc_today()

    Stream.iterate(today, &Date.add(&1, -1))
    |> Enum.reduce_while(0, fn date, streak ->
      if MapSet.member?(listened_dates, date), do: {:cont, streak + 1}, else: {:halt, streak}
    end)
  end

  @doc """
  Starts a server-captured listening session, used by the web player.
  """
  def start_listening_session(%Scope{user: user}, book, attrs \\ []) when not is_nil(user) do
    now = DateTime.utc_now(:second)

    %ListeningSession{}
    |> ListeningSession.changeset(%{
      id: Ecto.UUID.generate(),
      user_id: user.id,
      book_id: book.id,
      title: book.title,
      authors: book_authors_string(book),
      play_method: Keyword.get(attrs, :play_method, "Direct Play"),
      device_info: Keyword.get(attrs, :device_info, "Pageless Web"),
      started_at: now,
      updated_at_client: now,
      ended_at: nil,
      time_listened_seconds: 0,
      last_position_seconds: Keyword.get(attrs, :position_seconds, 0.0),
      duration_seconds: book.duration_seconds || 0.0
    })
    |> Repo.insert()
  end

  def add_listening_time(%Scope{user: user}, session_id, seconds, position_seconds)
      when not is_nil(user) do
    seconds = max(to_int(seconds), 0)
    now = DateTime.utc_now(:second)

    from(s in ListeningSession, where: s.id == ^session_id and s.user_id == ^user.id)
    |> Repo.update_all(
      inc: [time_listened_seconds: seconds],
      set: [
        updated_at_client: now,
        last_position_seconds: max(to_float(position_seconds), 0.0),
        updated_at: now
      ]
    )

    :ok
  end

  def end_listening_session(%Scope{user: user}, session_id, position_seconds)
      when not is_nil(user) do
    now = DateTime.utc_now(:second)

    from(s in ListeningSession, where: s.id == ^session_id and s.user_id == ^user.id)
    |> Repo.update_all(
      set: [
        ended_at: now,
        updated_at_client: now,
        last_position_seconds: max(to_float(position_seconds), 0.0),
        updated_at: now
      ]
    )

    :ok
  end

  def record_listening_event(%Scope{user: user}, session_id, book_id, event, position_seconds)
      when not is_nil(user) do
    %ListeningEvent{}
    |> ListeningEvent.changeset(%{
      id: Ecto.UUID.generate(),
      user_id: user.id,
      book_id: book_id,
      session_id: session_id,
      event: event,
      type: "Playback",
      position_seconds: max(to_float(position_seconds), 0.0),
      occurred_at: DateTime.utc_now(:second),
      server_sync_attempted: false
    })
    |> Repo.insert()
  end

  defp normalize_session_opts(opts) do
    %{
      page: max(to_int(Keyword.get(opts, :page, 1)), 1),
      per_page: Keyword.get(opts, :per_page, 10) |> to_int() |> clamp(1, 100),
      user_id: Keyword.get(opts, :user_id),
      sort: Keyword.get(opts, :sort, :updated_at_client),
      direction: Keyword.get(opts, :direction, :desc)
    }
  end

  defp listening_session_filters(query, %{user_id: user_id}) when user_id in [nil, ""], do: query

  defp listening_session_filters(query, %{user_id: user_id}) do
    where(query, [s], s.user_id == ^user_id)
  end

  defp order_listening_sessions(query, %{sort: sort, direction: direction}) do
    direction = if direction in [:asc, "asc"], do: :asc, else: :desc

    field =
      case sort do
        s when s in [:title, "title"] -> :title
        s when s in [:play_method, "play_method"] -> :play_method
        s when s in [:time_listened_seconds, "time_listened_seconds"] -> :time_listened_seconds
        s when s in [:last_position_seconds, "last_position_seconds"] -> :last_position_seconds
        _ -> :updated_at_client
      end

    order_by(query, [s], [{^direction, field(s, ^field)}])
  end

  defp clamp(value, min, max), do: value |> max(min) |> min(max)

  defp book_authors_string(%{authors: authors}) do
    if Ecto.assoc_loaded?(authors) do
      Enum.map_join(authors || [], ", ", & &1.name)
    end
  end

  defp book_authors_string(_book), do: nil

  defp insert_progress(user, book_id, current, duration, played_at) do
    now = DateTime.utc_now(:second)
    finished_at = if finished_at_position?(current, duration), do: played_at, else: nil

    attrs = %{
      user_id: user.id,
      book_id: book_id,
      current_seconds: current,
      duration_seconds: duration,
      last_played_at: played_at,
      finished_at: finished_at,
      started_at: played_at,
      deleted_at: nil,
      inserted_at: now,
      updated_at: now
    }

    # Upsert on the unique (user, book) key so a tombstoned record is revived
    # rather than colliding (get_progress hides tombstones, so we may not see it).
    # `started_at` is omitted from the replace list so it is preserved if a row
    # already exists.
    Repo.insert_all(
      PlaybackProgress,
      [attrs],
      on_conflict:
        {:replace,
         [
           :current_seconds,
           :duration_seconds,
           :last_played_at,
           :finished_at,
           :deleted_at,
           :updated_at
         ]},
      conflict_target: [:user_id, :book_id]
    )

    {:ok, Repo.get_by(PlaybackProgress, user_id: user.id, book_id: book_id)}
  end

  defp update_progress(existing, current, duration, played_at) do
    finished_at = if finished_at_position?(current, duration), do: played_at, else: nil

    existing
    |> PlaybackProgress.changeset(%{
      current_seconds: current,
      duration_seconds: duration,
      last_played_at: played_at,
      finished_at: finished_at
    })
    |> Repo.update()
  end

  defp upsert_listening_session(user, attrs) do
    now = DateTime.utc_now(:second)
    id = attrs["id"] || attrs[:id]

    row = %{
      id: id,
      user_id: user.id,
      book_id: attrs["book_id"] || attrs[:book_id],
      title: attrs["title"] || attrs[:title],
      authors: attrs["authors"] || attrs[:authors],
      play_method: attrs["play_method"] || attrs[:play_method] || "Unknown",
      device_info: attrs["device_info"] || attrs[:device_info] || "Unknown device",
      started_at: normalize_datetime(attrs["started_at"] || attrs[:started_at]) || now,
      updated_at_client: normalize_datetime(attrs["updated_at"] || attrs[:updated_at]) || now,
      ended_at: normalize_datetime(attrs["ended_at"] || attrs[:ended_at]),
      time_listened_seconds:
        max(to_int(attrs["time_listened_seconds"] || attrs[:time_listened_seconds]), 0),
      last_position_seconds:
        max(to_float(attrs["last_position_seconds"] || attrs[:last_position_seconds]), 0.0),
      duration_seconds: max(to_float(attrs["duration_seconds"] || attrs[:duration_seconds]), 0.0),
      inserted_at: now,
      updated_at: now
    }

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

    id
  end

  defp upsert_listening_event(user, attrs) do
    now = DateTime.utc_now(:second)

    row = %{
      id: attrs["id"] || attrs[:id],
      user_id: user.id,
      book_id: attrs["book_id"] || attrs[:book_id],
      session_id: attrs["session_id"] || attrs[:session_id],
      event: attrs["event"] || attrs[:event],
      type: attrs["type"] || attrs[:type] || "Playback",
      position_seconds: max(to_float(attrs["position_seconds"] || attrs[:position_seconds]), 0.0),
      occurred_at: normalize_datetime(attrs["timestamp"] || attrs[:timestamp]) || now,
      server_sync_attempted:
        to_bool(attrs["server_sync_attempted"] || attrs[:server_sync_attempted]),
      server_sync_success:
        to_nullable_bool(attrs["server_sync_success"] || attrs[:server_sync_success]),
      server_sync_message: attrs["server_sync_message"] || attrs[:server_sync_message],
      inserted_at: now,
      updated_at: now
    }

    Repo.insert_all(
      ListeningEvent,
      [row],
      on_conflict:
        {:replace,
         [
           :event,
           :type,
           :position_seconds,
           :occurred_at,
           :server_sync_attempted,
           :server_sync_success,
           :server_sync_message,
           :updated_at
         ]},
      conflict_target: [:id]
    )
  end

  defp stale?(_incoming, nil), do: false
  defp stale?(incoming, stored), do: DateTime.compare(incoming, stored) == :lt

  defp book_exists?(book_id) do
    Repo.exists?(from b in Pageless.Library.Book, where: b.id == ^book_id)
  end

  defp accessible_library_filter(user) do
    case Accounts.accessible_library_ids(%Scope{user: user}) do
      :all -> dynamic([_p, _b], true)
      [] -> dynamic([_p, _b], false)
      library_ids -> dynamic([_p, b], b.library_id in ^library_ids)
    end
  end

  defp to_float(nil), do: 0.0
  defp to_float(n) when is_number(n), do: n * 1.0

  defp to_float(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp to_int(nil), do: 0
  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_float(n), do: trunc(n)

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp to_bool(true), do: true
  defp to_bool(_), do: false

  defp to_nullable_bool(nil), do: nil
  defp to_nullable_bool(v), do: to_bool(v)

  defp normalize_datetime(%DateTime{} = dt), do: DateTime.truncate(dt, :second)

  defp normalize_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp normalize_datetime(_), do: nil

  ## Bookmarks

  @doc """
  Lists the scoped user's active (non-deleted) bookmarks for a book, ordered by
  position.
  """
  def list_bookmarks(%Scope{user: user}, book_id) when not is_nil(user) do
    Bookmark
    |> where([b], b.user_id == ^user.id and b.book_id == ^book_id and is_nil(b.deleted_at))
    |> order_by(asc: :position_seconds)
    |> Repo.all()
  end

  @doc """
  Creates a bookmark at `position_seconds` (with an optional note) for the
  scoped user and book.
  """
  def create_bookmark(%Scope{user: user}, book_id, position_seconds, note \\ nil)
      when not is_nil(user) do
    %Bookmark{user_id: user.id, book_id: book_id}
    |> Bookmark.changeset(%{
      position_seconds: max(position_seconds * 1.0, 0.0),
      note: normalize_note(note)
    })
    |> Repo.insert()
  end

  @doc """
  Lists all of the scoped user's bookmarks across books (optionally only those
  updated at or after `since`), oldest-updated first. Includes soft-deleted
  bookmarks (as tombstones) so clients can remove them locally on sync.
  """
  def list_all_bookmarks(%Scope{user: user}, since \\ nil) when not is_nil(user) do
    Bookmark
    |> where(user_id: ^user.id)
    |> then(fn q -> if since, do: where(q, [b], b.updated_at >= ^since), else: q end)
    |> order_by([b], asc: b.updated_at)
    |> Repo.all()
  end

  @doc """
  Idempotently creates or updates a bookmark with a client-supplied `id`, for
  offline-first sync. Re-sending the same id updates the note/position rather
  than creating a duplicate.
  """
  def upsert_bookmark(%Scope{user: user}, id, book_id, position_seconds, note)
      when not is_nil(user) and is_binary(id) do
    now = DateTime.utc_now(:second)

    attrs = %{
      id: id,
      user_id: user.id,
      book_id: book_id,
      position_seconds: max(to_float(position_seconds), 0.0),
      note: normalize_note(note),
      deleted_at: nil,
      inserted_at: now,
      updated_at: now
    }

    Repo.insert_all(
      Bookmark,
      [attrs],
      # Re-upserting an id clears any tombstone (deleted_at -> nil).
      on_conflict: {:replace, [:position_seconds, :note, :deleted_at, :updated_at]},
      conflict_target: [:id]
    )

    {:ok, Repo.get_by(Bookmark, id: id, user_id: user.id)}
  end

  @doc """
  Soft-deletes a bookmark owned by the scoped user (sets `deleted_at`), so the
  deletion propagates to other devices via the sync feed. Returns `:ok`.
  """
  def delete_bookmark(%Scope{user: user}, bookmark_id) when not is_nil(user) do
    now = DateTime.utc_now(:second)

    Bookmark
    |> where([b], b.id == ^bookmark_id and b.user_id == ^user.id and is_nil(b.deleted_at))
    |> Repo.update_all(set: [deleted_at: now, updated_at: now])

    :ok
  end

  defp normalize_note(nil), do: nil

  defp normalize_note(note) when is_binary(note) do
    case String.trim(note) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
