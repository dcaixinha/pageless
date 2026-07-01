defmodule PagelessWeb.LibraryLive.PlaylistsTest do
  use PagelessWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Pageless.AccountsFixtures
  import Pageless.LibraryFixtures

  alias Pageless.Library

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), scope: user_scope_fixture(user)}
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/playlists")
  end

  test "renders empty state when there are no playlists", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/playlists")
    assert html =~ "No playlists yet"
  end

  test "creates a playlist from the index", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/playlists")

    lv |> form("#new-playlist-form", %{"name" => "Roadtrip"}) |> render_submit()

    assert render(lv) =~ "Roadtrip"
  end

  test "lists playlists and shows member books, allows removing", %{conn: conn, scope: scope} do
    library = library_fixture()
    book = book_fixture(%{library: library, title: "The Hobbit"})
    {:ok, playlist} = Library.create_playlist(scope, "Faves")
    {:ok, _} = Library.add_book_to_playlist(scope, playlist.id, book.id)

    {:ok, lv, _html} = live(conn, ~p"/playlists")
    assert has_element?(lv, "#playlist-#{playlist.id}")

    {:ok, show_lv, html} = live(conn, ~p"/playlists/#{playlist.id}")
    assert html =~ "Faves"
    assert has_element?(show_lv, "#playlist-book-#{book.id}")

    show_lv
    |> element(~s|button[phx-click=remove_book][phx-value-book-id="#{book.id}"]|)
    |> render_click()

    refute has_element?(show_lv, "#playlist-book-#{book.id}")
    assert Library.get_playlist(scope, playlist.id).playlist_books == []
  end

  test "searches for and adds books on the show page", %{conn: conn, scope: scope} do
    library = library_fixture()
    book = book_fixture(%{library: library, title: "Searchable Title"})
    {:ok, playlist} = Library.create_playlist(scope, "Growing")

    {:ok, show_lv, _html} = live(conn, ~p"/playlists/#{playlist.id}")

    # Search surfaces the book.
    html =
      show_lv
      |> form("#playlist-add-form", %{"query" => "Searchable"})
      |> render_change()

    assert html =~ "Searchable Title"
    assert has_element?(show_lv, ~s|button[phx-click=add_book][phx-value-book-id="#{book.id}"]|)

    # Adding it puts it in the playlist and removes it from results.
    show_lv
    |> element(~s|button[phx-click=add_book][phx-value-book-id="#{book.id}"]|)
    |> render_click()

    assert has_element?(show_lv, "#playlist-book-#{book.id}")
    refute has_element?(show_lv, "#add-result-#{book.id}")

    assert Enum.map(Library.get_playlist(scope, playlist.id).playlist_books, & &1.book_id) == [
             book.id
           ]
  end

  test "deletes a playlist from the detail view", %{conn: conn, scope: scope} do
    {:ok, playlist} = Library.create_playlist(scope, "Temp")

    {:ok, show_lv, _html} = live(conn, ~p"/playlists/#{playlist.id}")

    show_lv
    |> element("button[phx-click=delete_playlist]")
    |> render_click()

    assert Library.list_playlists(scope) == []
  end

  test "does not show another user's playlist", %{conn: conn} do
    other = user_scope_fixture(user_fixture())
    {:ok, playlist} = Library.create_playlist(other, "Private")

    assert {:error, {:live_redirect, %{to: "/playlists"}}} =
             live(conn, ~p"/playlists/#{playlist.id}")
  end
end
