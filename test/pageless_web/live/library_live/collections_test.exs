defmodule PagelessWeb.LibraryLive.CollectionsTest do
  use PagelessWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Pageless.AccountsFixtures
  import Pageless.LibraryFixtures

  alias Pageless.Library

  setup %{conn: conn} do
    admin = admin_user_fixture()
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/collections")
  end

  test "renders empty state when there are no collections", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/collections")
    assert html =~ "No collections yet"
  end

  test "lists collections and navigates to detail", %{conn: conn} do
    library = library_fixture()
    book = book_fixture(%{library: library, title: "The Hobbit"})
    collection = Library.upsert_collection(library.id, "Fantasy")
    Library.set_collection_books(collection, [book.id])

    {:ok, lv, _html} = live(conn, ~p"/collections")
    assert has_element?(lv, "#collection-#{collection.id}")
    assert render(lv) =~ "Fantasy"

    {:ok, show_lv, html} = live(conn, ~p"/collections/#{collection.id}")
    assert html =~ "Fantasy"
    assert has_element?(show_lv, "#collection-book-#{book.id}")
    assert render(show_lv) =~ "The Hobbit"
  end

  test "searches for and adds books on the show page", %{conn: conn} do
    library = library_fixture()
    book = book_fixture(%{library: library, title: "Searchable Title"})
    collection = Library.upsert_collection(library.id, "Growing")

    {:ok, show_lv, _html} = live(conn, ~p"/collections/#{collection.id}")

    html =
      show_lv
      |> form("#collection-add-form", %{"query" => "Searchable"})
      |> render_change()

    assert html =~ "Searchable Title"
    assert has_element?(show_lv, ~s|button[phx-click=add_book][phx-value-book-id="#{book.id}"]|)

    show_lv
    |> element(~s|button[phx-click=add_book][phx-value-book-id="#{book.id}"]|)
    |> render_click()

    assert has_element?(show_lv, "#collection-book-#{book.id}")
    refute has_element?(show_lv, "#add-result-#{book.id}")

    scope = user_scope_fixture(admin_user_fixture())

    assert Enum.map(Library.get_collection(scope, collection.id).book_collections, & &1.book_id) ==
             [book.id]
  end

  test "removes a book from the show page", %{conn: conn} do
    library = library_fixture()
    book = book_fixture(%{library: library, title: "To Remove"})
    collection = Library.upsert_collection(library.id, "List")
    Library.set_collection_books(collection, [book.id])

    {:ok, show_lv, _html} = live(conn, ~p"/collections/#{collection.id}")
    assert has_element?(show_lv, "#collection-book-#{book.id}")

    show_lv
    |> element(~s|button[phx-click=remove_book][phx-value-book-id="#{book.id}"]|)
    |> render_click()

    refute has_element?(show_lv, "#collection-book-#{book.id}")
  end
end
