defmodule PagelessWeb.API.BookmarkControllerTest do
  use PagelessWeb.ConnCase, async: true

  import Pageless.AccountsFixtures
  import Pageless.LibraryFixtures

  alias Pageless.Accounts
  alias Pageless.Playback

  setup %{conn: conn} do
    user = set_password(user_fixture())
    {:ok, {token, _}} = Accounts.create_api_token(user.email, valid_user_password(), "test")

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn, scope: user_scope_fixture(user), book: book_fixture()}
  end

  test "requires authentication", %{book: book} do
    conn = build_conn() |> put_req_header("accept", "application/json")
    assert json_response(get(conn, ~p"/api/books/#{book.id}/bookmarks"), 401)
  end

  test "PUT upserts a bookmark with a client id", %{conn: conn, book: book} do
    id = Ecto.UUID.generate()

    conn =
      put(conn, ~p"/api/bookmarks/#{id}", %{
        book_id: book.id,
        position_seconds: 120.0,
        note: "here"
      })

    assert %{"bookmark" => bm} = json_response(conn, 200)
    assert bm["id"] == id
    assert bm["position_seconds"] == 120.0
    assert bm["note"] == "here"
  end

  test "PUT is idempotent (updates, no duplicate)", %{conn: conn, scope: scope, book: book} do
    id = Ecto.UUID.generate()
    put(conn, ~p"/api/bookmarks/#{id}", %{book_id: book.id, position_seconds: 10.0})

    put(build_authed(conn), ~p"/api/bookmarks/#{id}", %{
      book_id: book.id,
      position_seconds: 99.0,
      note: "x"
    })

    bookmarks = Playback.list_bookmarks(scope, book.id)
    assert [%{position_seconds: 99.0, note: "x"}] = bookmarks
  end

  test "GET /api/books/:id/bookmarks lists them", %{conn: conn, scope: scope, book: book} do
    {:ok, _} = Playback.create_bookmark(scope, book.id, 50.0, "a")
    conn = get(conn, ~p"/api/books/#{book.id}/bookmarks")
    assert [%{"note" => "a"}] = json_response(conn, 200)["bookmarks"]
  end

  test "GET /api/bookmarks?since= filters by updated_at", %{conn: conn, scope: scope, book: book} do
    {:ok, _} = Playback.create_bookmark(scope, book.id, 50.0, "a")

    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
    assert [_] = json_response(get(conn, ~p"/api/bookmarks?since=#{past}"), 200)["bookmarks"]

    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

    assert [] ==
             json_response(get(build_authed(conn), ~p"/api/bookmarks?since=#{future}"), 200)[
               "bookmarks"
             ]
  end

  test "DELETE removes a bookmark", %{conn: conn, scope: scope, book: book} do
    {:ok, bm} = Playback.create_bookmark(scope, book.id, 10.0, nil)
    assert response(delete(conn, ~p"/api/bookmarks/#{bm.id}"), 204)
    assert Playback.list_bookmarks(scope, book.id) == []
  end

  defp build_authed(conn) do
    [auth] = get_req_header(conn, "authorization")

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", auth)
  end
end
