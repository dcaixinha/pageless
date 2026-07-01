defmodule PagelessWeb.HomeLiveTest do
  use PagelessWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Pageless.AccountsFixtures
  import Pageless.LibraryFixtures

  alias Pageless.Playback
  alias Pageless.Accounts

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), scope: user_scope_fixture(user)}
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/")
  end

  test "shows an empty state with no activity and no books", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ "Nothing here yet"
  end

  test "shows recently added books under Discover", %{conn: conn} do
    book_fixture(%{title: "Brand New Book"})

    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ "Discover"
    assert html =~ "Brand New Book"
  end

  test "uses and persists the user's cover size", %{conn: conn, scope: scope} do
    book_fixture(%{title: "Resizable Book"})
    Accounts.update_player_settings(scope.user, %{"cover_size" => "220"})

    {:ok, lv, html} = live(conn, ~p"/")
    assert html =~ "--book-cover-size: 220px"

    lv
    |> element("#cover-size-control button[aria-label='Increase cover size']")
    |> render_click()

    assert render(lv) =~ "--book-cover-size: 240px"
    assert Accounts.get_player_settings(Accounts.get_user!(scope.user.id)).cover_size == 240
  end

  test "shows in-progress books under Continue Listening", %{conn: conn, scope: scope} do
    book = book_fixture(%{title: "Halfway Book", duration_seconds: 1000.0})
    Playback.save_progress(scope, book.id, 400.0, 1000.0)

    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ "Continue Listening"
    assert html =~ "Halfway Book"
  end

  test "shows finished books under Listen Again", %{conn: conn, scope: scope} do
    book = book_fixture(%{title: "Done Book", duration_seconds: 1000.0})
    # Near the end marks it finished.
    Playback.save_progress(scope, book.id, 990.0, 1000.0)

    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ "Listen Again"
    assert html =~ "Done Book"
  end

  test "in-progress books do not appear in Listen Again", %{conn: conn, scope: scope} do
    book = book_fixture(%{title: "Ongoing", duration_seconds: 1000.0})
    Playback.save_progress(scope, book.id, 100.0, 1000.0)

    {:ok, lv, _html} = live(conn, ~p"/")
    refute has_element?(lv, "section", "Listen Again")
  end

  test "finished books are excluded from Discover", %{conn: conn, scope: scope} do
    book = book_fixture(%{title: "Finished Book", duration_seconds: 1000.0})
    Playback.mark_finished(scope, book.id, 1000.0)

    {:ok, lv, _html} = live(conn, ~p"/")

    refute has_element?(lv, "#shelf-discover a[href='/books/#{book.id}']")
    assert has_element?(lv, "#shelf-finished a[href='/books/#{book.id}']")
  end

  test "in-progress books are excluded from Discover", %{conn: conn, scope: scope} do
    book = book_fixture(%{title: "Started Book", duration_seconds: 1000.0})
    Playback.save_progress(scope, book.id, 100.0, 1000.0)

    {:ok, lv, _html} = live(conn, ~p"/")

    refute has_element?(lv, "#shelf-discover a[href='/books/#{book.id}']")
    assert has_element?(lv, "#shelf-continue a[href='/books/#{book.id}']")
  end
end
