defmodule PagelessWeb.API.HomeControllerTest do
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

    %{conn: conn, scope: user_scope_fixture(user)}
  end

  test "requires authentication" do
    conn = build_conn() |> put_req_header("accept", "application/json")
    assert json_response(get(conn, ~p"/api/home"), 401)
  end

  test "returns the three shelves", %{conn: conn} do
    conn = get(conn, ~p"/api/home")
    body = json_response(conn, 200)
    assert Map.has_key?(body, "continue_listening")
    assert Map.has_key?(body, "discover")
    assert Map.has_key?(body, "listen_again")
  end

  test "places a started book in continue_listening with progress", %{conn: conn, scope: scope} do
    book = book_fixture(%{title: "In Progress", duration_seconds: 1000.0})
    Playback.save_progress(scope, book.id, 300.0, 1000.0)

    body = json_response(get(conn, ~p"/api/home"), 200)
    entry = Enum.find(body["continue_listening"], &(&1["id"] == book.id))
    assert entry
    assert entry["progress"]["current_seconds"] == 300.0
    # A started book is excluded from discover.
    refute Enum.any?(body["discover"], &(&1["id"] == book.id))
  end

  test "places a finished book in listen_again", %{conn: conn, scope: scope} do
    book = book_fixture(%{title: "Done", duration_seconds: 1000.0})
    Playback.mark_finished(scope, book.id, 1000.0)

    body = json_response(get(conn, ~p"/api/home"), 200)
    assert Enum.any?(body["listen_again"], &(&1["id"] == book.id))
  end

  test "shows unstarted books in discover", %{conn: conn} do
    book = book_fixture(%{title: "Fresh"})
    body = json_response(get(conn, ~p"/api/home"), 200)
    assert Enum.any?(body["discover"], &(&1["id"] == book.id))
  end
end
