defmodule PagelessWeb.API.ProgressControllerTest do
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

    %{conn: conn, user: user, scope: user_scope_fixture(user)}
  end

  test "POST /api/progress/:book_id creates progress", %{conn: conn} do
    book = book_fixture(%{duration_seconds: 1000.0})

    conn =
      post(conn, ~p"/api/progress/#{book.id}", %{
        current_seconds: 250.0,
        duration_seconds: 1000.0,
        last_played_at: DateTime.to_iso8601(DateTime.utc_now())
      })

    assert %{"progress" => p} = json_response(conn, 200)
    assert p["current_seconds"] == 250.0
    assert p["finished"] == false
  end

  test "POST marks finished when position passes threshold", %{conn: conn} do
    book = book_fixture(%{duration_seconds: 1000.0})

    conn =
      post(conn, ~p"/api/progress/#{book.id}", %{
        current_seconds: 995.0,
        duration_seconds: 1000.0,
        last_played_at: DateTime.to_iso8601(DateTime.utc_now())
      })

    assert json_response(conn, 200)["progress"]["finished"] == true
  end

  test "POST 404s for unknown book", %{conn: conn} do
    conn =
      post(conn, ~p"/api/progress/#{Ecto.UUID.generate()}", %{
        current_seconds: 1.0,
        duration_seconds: 1000.0
      })

    assert json_response(conn, 404)
  end

  test "last-write-wins: a stale update does not overwrite a newer record", %{
    conn: conn,
    scope: scope
  } do
    book = book_fixture(%{duration_seconds: 1000.0})
    # Server already has a newer position.
    Playback.save_progress(scope, book.id, 800.0, 1000.0)

    stale_time = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()

    conn =
      post(conn, ~p"/api/progress/#{book.id}", %{
        current_seconds: 100.0,
        duration_seconds: 1000.0,
        last_played_at: stale_time
      })

    # Stale update is ignored; server value is returned unchanged.
    assert json_response(conn, 200)["progress"]["current_seconds"] == 800.0
  end

  test "GET /api/progress?since= returns records changed since a timestamp", %{
    conn: conn,
    scope: scope
  } do
    book = book_fixture(%{duration_seconds: 1000.0})
    Playback.save_progress(scope, book.id, 120.0, 1000.0)

    # since in the past → included
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
    conn1 = get(conn, ~p"/api/progress?since=#{past}")
    assert [%{"book_id" => book_id}] = json_response(conn1, 200)["progress"]
    assert book_id == book.id

    # since in the future → excluded
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
    conn2 = get(build_authed_conn(conn), ~p"/api/progress?since=#{future}")
    assert json_response(conn2, 200)["progress"] == []
  end

  # A fresh conn carrying the same auth header (needed after a request is "used").
  defp build_authed_conn(conn) do
    [auth] = get_req_header(conn, "authorization")

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", auth)
  end
end
