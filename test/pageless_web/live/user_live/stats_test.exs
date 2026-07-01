defmodule PagelessWeb.UserLive.StatsTest do
  use PagelessWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Pageless.AccountsFixtures
  import Pageless.LibraryFixtures

  alias Pageless.Accounts.Scope
  alias Pageless.Accounts
  alias Pageless.Library
  alias Pageless.Playback

  describe "stats page" do
    test "requires authentication", %{conn: conn} do
      user_fixture()

      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/users/stats")
    end

    test "renders user stats", %{conn: conn} do
      user = user_fixture(first_name: "Stats")
      scope = Scope.for_user(user)

      book =
        book_fixture(%{
          title: "Stats Book",
          duration_seconds: 1000.0,
          cover_path: "/tmp/stats.jpg"
        })

      Playback.save_progress(scope, book.id, 1000.0, 1000.0)
      session = session_fixture(user, book, time_listened: 1_800, position: 123.0)

      {:ok, lv, html} = conn |> log_in_user(user) |> live(~p"/users/stats")

      assert html =~ "Your Stats"
      assert html =~ "Items Finished"
      assert html =~ "Days Listened"
      assert html =~ "Minutes Listening"
      assert html =~ "Stats Book"
      assert html =~ "30m 0s"
      assert html =~ "Week Listening"
      assert html =~ "Less"
      assert html =~ "More"
      assert html =~ "listening on"
      assert html =~ "#{session.title}"
      review_year = Date.utc_today().year - 1
      assert html =~ "Year in Review"
      refute html =~ "Pageless #{review_year} Year in Review"

      html = lv |> element("button", "Year in Review") |> render_click()
      assert html =~ "#{review_year}"
      assert html =~ "Pageless #{review_year} Year in Review"
      assert html =~ "books finished"
      assert html =~ "spent listening"

      html = lv |> element("button[aria-label='Next year']") |> render_click()

      assert html =~ "/books/#{book.id}/cover"
    end

    test "uses the viewer's date preference in chart tooltips", %{conn: conn} do
      user = user_fixture()

      {:ok, user} =
        Accounts.update_player_settings(user, %{"date_format" => "yyyy-MM-dd"})

      book = book_fixture(%{title: "Dated Stats Book"})
      session_fixture(user, book, time_listened: 60)

      {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/users/stats")

      assert html =~ "listening on #{Date.to_iso8601(Date.utc_today())}"
    end

    test "top bar links to stats", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/")
      assert has_element?(lv, ~s(a[href="/users/stats"]), "Stats")
    end

    test "renders library stats tab for regular users", %{conn: conn} do
      book = book_fixture(%{title: "Long Book", duration_seconds: 7200.0, size: 1024})
      audio_file_fixture(book, %{size: 2_147_483_648, duration_seconds: 7200.0})

      {:ok, _book} =
        book
        |> Library.update_book(%{"authors" => "Ada Author", "genres" => "History, Science"})

      user = user_fixture()

      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/users/stats")
      html = lv |> element("button", "Library Stats") |> render_click()

      assert html =~ "Library Stats"
      assert html =~ "Items in Library"
      assert html =~ "Overall Hours"
      assert html =~ "Authors"
      assert html =~ "Size (GB)"
      assert html =~ "Audio Tracks"
      assert html =~ "Top Genres"
      assert html =~ "History"
      assert html =~ "Science"
      assert html =~ "Top Authors"
      assert html =~ "Ada Author"
      assert html =~ "Longest Items"
      assert html =~ "Long Book"
      assert html =~ "Largest Items"
    end

    test "scopes library stats to accessible libraries", %{conn: conn} do
      visible_library = library_fixture()
      hidden_library = library_fixture()
      visible_book = book_fixture(%{library: visible_library, title: "Visible Book"})
      hidden_book = book_fixture(%{library: hidden_library, title: "Hidden Book"})

      audio_file_fixture(visible_book)
      audio_file_fixture(hidden_book)

      admin = admin_user_fixture()
      scope = Scope.for_user(admin)

      {:ok, user} =
        Pageless.Accounts.create_managed_user(scope, %{
          email: unique_user_email(),
          password: valid_user_password(),
          permissions: %{can_access_all_libraries: false},
          library_ids: [visible_library.id]
        })

      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/users/stats")
      html = lv |> element("button", "Library Stats") |> render_click()

      assert html =~ "Visible Book"
      refute html =~ "Hidden Book"
    end
  end

  defp session_fixture(user, book, opts) do
    scope = Scope.for_user(user)

    {:ok, session} =
      Playback.start_listening_session(scope, book,
        play_method: "Direct Play",
        device_info: "Pageless Web\nFirefox",
        position_seconds: Keyword.get(opts, :position, 0.0)
      )

    Playback.add_listening_time(
      scope,
      session.id,
      Keyword.get(opts, :time_listened, 60),
      Keyword.get(opts, :position, 0.0)
    )

    session
  end
end
