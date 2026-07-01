defmodule PagelessWeb.API.PlaylistControllerTest do
  use PagelessWeb.ConnCase, async: true

  import Pageless.AccountsFixtures
  import Pageless.LibraryFixtures

  alias Pageless.Accounts
  alias Pageless.Library

  setup %{conn: conn} do
    user = set_password(user_fixture())
    {:ok, {token, _}} = Accounts.create_api_token(user.email, valid_user_password(), "test")

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn, scope: user_scope_fixture(user)}
  end

  test "unauthenticated requests are rejected" do
    conn = build_conn() |> put_req_header("accept", "application/json")
    assert json_response(get(conn, ~p"/api/playlists"), 401)
  end

  test "GET /api/playlists lists the user's playlists with books", %{conn: conn, scope: scope} do
    library = library_fixture()
    book = book_fixture(%{library: library, title: "The Hobbit"})
    {:ok, playlist} = Library.create_playlist(scope, "Faves")
    {:ok, _} = Library.add_book_to_playlist(scope, playlist.id, book.id)

    conn = get(conn, ~p"/api/playlists")
    assert %{"playlists" => [p]} = json_response(conn, 200)
    assert p["name"] == "Faves"
    assert [b] = p["books"]
    assert b["id"] == book.id
  end

  test "GET /api/playlists/:id returns 404 for another user's playlist", %{conn: conn} do
    other = user_scope_fixture(user_fixture())
    {:ok, playlist} = Library.create_playlist(other, "Private")

    conn = get(conn, ~p"/api/playlists/#{playlist.id}")
    assert json_response(conn, 404)
  end
end
