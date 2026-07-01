defmodule PagelessWeb.API.SeriesControllerTest do
  use PagelessWeb.ConnCase, async: true

  import Pageless.AccountsFixtures
  import Pageless.LibraryFixtures

  alias Pageless.Accounts
  alias Pageless.Library

  setup %{conn: conn} do
    user = set_password(admin_user_fixture())
    {:ok, {token, _}} = Accounts.create_api_token(user.email, valid_user_password(), "test")

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn}
  end

  test "unauthenticated requests are rejected" do
    conn = build_conn() |> put_req_header("accept", "application/json")
    assert json_response(get(conn, ~p"/api/series"), 401)
  end

  test "GET /api/series lists series with ordered books", %{conn: conn} do
    library = library_fixture()
    b1 = book_fixture(%{library: library, title: "One"})
    b2 = book_fixture(%{library: library, title: "Two"})
    Library.set_book_series(b1, [%{name: "Saga", sequence: "1"}])
    Library.set_book_series(b2, [%{name: "Saga", sequence: "2"}])

    conn = get(conn, ~p"/api/series")
    assert %{"series" => [s]} = json_response(conn, 200)
    assert s["name"] == "Saga"
    assert Enum.map(s["books"], & &1["title"]) == ["One", "Two"]
    assert Enum.map(s["books"], & &1["sequence"]) == ["1", "2"]
  end

  test "GET /api/series/:id returns 404 for unknown id", %{conn: conn} do
    conn = get(conn, ~p"/api/series/#{Ecto.UUID.generate()}")
    assert json_response(conn, 404)
  end
end
