defmodule PagelessWeb.SettingsLive.ListeningSessionsTest do
  use PagelessWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Pageless.AccountsFixtures
  import Pageless.LibraryFixtures

  alias Pageless.Accounts.Scope
  alias Pageless.Accounts
  alias Pageless.Playback

  describe "access control" do
    test "redirects non-admin users", %{conn: conn} do
      user = user_fixture()

      assert {:error, {:redirect, %{to: "/"}}} =
               conn |> log_in_user(user) |> live(~p"/settings/listening-sessions")
    end

    test "redirects anonymous users", %{conn: conn} do
      user_fixture()

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(conn, ~p"/settings/listening-sessions")
    end
  end

  describe "as admin" do
    setup %{conn: conn} do
      admin = admin_user_fixture(first_name: "Admin")
      %{conn: log_in_user(conn, admin), admin: admin}
    end

    test "renders listening sessions", %{conn: conn} do
      user = named_user_fixture("Rita")
      book = book_fixture(%{title: "Grit"})
      session_fixture(user, book, time_listened: 1_800, position: 492.0)

      {:ok, _lv, html} = live(conn, ~p"/settings/listening-sessions")

      assert html =~ "Listening Sessions"
      assert html =~ "Grit"
      assert html =~ "Rita"
      assert html =~ "Direct Play"
      assert html =~ "Pageless Web"
      assert html =~ "30m 0s"
      assert html =~ "8:12"
    end

    test "uses the viewer's date and time preferences for exact timestamps", %{
      conn: conn,
      admin: admin
    } do
      {:ok, _admin} =
        Accounts.update_player_settings(admin, %{
          "date_format" => "MMMM do, yyyy",
          "time_format" => "h:mma"
        })

      user = named_user_fixture("Timestamp")
      book = book_fixture(%{title: "Timestamped Book"})
      session = session_fixture(user, book, time_listened: 60)

      session
      |> Ecto.Changeset.change(
        started_at: ~U[2024-01-02 15:04:05Z],
        updated_at_client: ~U[2024-03-04 05:06:07Z]
      )
      |> Pageless.Repo.update!()

      {:ok, lv, _html} = live(conn, ~p"/settings/listening-sessions")
      html = lv |> element("#listening-session-#{session.id}") |> render_click()

      assert html =~ "January 2nd, 2024 3:04:05PM UTC"
      assert html =~ "March 4th, 2024 5:06:07AM UTC"
    end

    test "filters by user", %{conn: conn} do
      first = named_user_fixture("First")
      second = named_user_fixture("Second")
      book = book_fixture(%{title: "Filtered Book"})
      first_session = session_fixture(first, book, time_listened: 10)
      second_session = session_fixture(second, book, time_listened: 20)

      {:ok, lv, _html} = live(conn, ~p"/settings/listening-sessions")

      html =
        lv
        |> form("#session-user-filter", %{user_id: second.id})
        |> render_change()

      assert html =~ "Second"
      assert has_element?(lv, "#listening-session-#{second_session.id}")
      refute has_element?(lv, "#listening-session-#{first_session.id}")
    end

    test "paginates sessions", %{conn: conn} do
      user = named_user_fixture("Pager")
      book = book_fixture(%{title: "Paged Book"})

      for n <- 1..11 do
        session_fixture(user, book, time_listened: n, title: "Session #{n}")
      end

      {:ok, lv, html} = live(conn, ~p"/settings/listening-sessions")
      assert html =~ "Page 1 of 2"

      html = lv |> element("button[phx-value-direction=next]") |> render_click()
      assert html =~ "Page 2 of 2"
    end

    test "opens a details modal and deletes a session", %{conn: conn} do
      user = named_user_fixture("Deleter")
      book = book_fixture(%{title: "Delete Me"})
      session = session_fixture(user, book, time_listened: 60, position: 12.0)

      {:ok, lv, _html} = live(conn, ~p"/settings/listening-sessions")

      html = lv |> element("#listening-session-#{session.id}") |> render_click()
      assert html =~ "listening-session-modal"
      assert html =~ ~s(phx-window-keydown="close_modal")
      assert html =~ "Delete Me"
      assert html =~ "Delete session"

      lv |> element("#listening-session-modal button", "Delete session") |> render_click()

      refute has_element?(lv, "#listening-session-#{session.id}")
      assert Pageless.Repo.get(Pageless.Playback.ListeningSession, session.id) == nil
    end
  end

  defp session_fixture(user, book, opts) do
    scope = Scope.for_user(user)

    {:ok, session} =
      Playback.start_listening_session(scope, book,
        play_method: Keyword.get(opts, :play_method, "Direct Play"),
        device_info: Keyword.get(opts, :device_info, "Pageless Web\nFirefox"),
        position_seconds: Keyword.get(opts, :position, 0.0)
      )

    Playback.add_listening_time(
      scope,
      session.id,
      Keyword.get(opts, :time_listened, 60),
      Keyword.get(opts, :position, 0.0)
    )

    if title = Keyword.get(opts, :title) do
      Pageless.Repo.update!(Ecto.Changeset.change(session, title: title))
    else
      session
    end
  end

  defp named_user_fixture(first_name) do
    user = user_fixture()
    {:ok, user} = Accounts.update_user_profile(user, %{first_name: first_name})
    user
  end
end
