defmodule PagelessWeb.API.CollectionControllerTest do
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
    assert json_response(get(conn, ~p"/api/collections"), 401)
  end

  test "GET /api/collections lists collections with books", %{conn: conn} do
    library = library_fixture()
    book = book_fixture(%{library: library, title: "The Hobbit"})
    collection = Library.upsert_collection(library.id, "Fantasy")
    Library.set_collection_books(collection, [book.id])

    conn = get(conn, ~p"/api/collections")
    assert %{"collections" => [c]} = json_response(conn, 200)
    assert c["name"] == "Fantasy"
    assert [b] = c["books"]
    assert b["id"] == book.id
    assert b["title"] == "The Hobbit"
  end

  test "GET /api/collections/:id returns a single collection", %{conn: conn} do
    library = library_fixture()
    book = book_fixture(%{library: library})
    collection = Library.upsert_collection(library.id, "Kids")
    Library.set_collection_books(collection, [book.id])

    conn = get(conn, ~p"/api/collections/#{collection.id}")
    assert %{"collection" => c} = json_response(conn, 200)
    assert c["id"] == collection.id
    assert length(c["books"]) == 1
  end

  test "GET /api/collections/:id returns 404 for unknown id", %{conn: conn} do
    conn = get(conn, ~p"/api/collections/#{Ecto.UUID.generate()}")
    assert json_response(conn, 404)
  end
end
