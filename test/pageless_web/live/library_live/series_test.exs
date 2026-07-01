defmodule PagelessWeb.LibraryLive.SeriesTest do
  use PagelessWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Pageless.AccountsFixtures
  import Pageless.LibraryFixtures

  alias Pageless.Library

  setup %{conn: conn} do
    admin = admin_user_fixture()
    %{conn: log_in_user(conn, admin)}
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/series")
  end

  test "renders empty state when there are no series", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/series")
    assert html =~ "No series yet"
  end

  test "lists series and shows member books in order", %{conn: conn} do
    library = library_fixture()
    b1 = book_fixture(%{library: library, title: "Ferias de Natal"})
    b2 = book_fixture(%{library: library, title: "Ferias de Verao"})
    Library.set_book_series(b1, [%{name: "Uma Aventura", sequence: "1"}])
    Library.set_book_series(b2, [%{name: "Uma Aventura", sequence: "2"}])

    {:ok, lv, _html} = live(conn, ~p"/series")
    assert render(lv) =~ "Uma Aventura"

    [series] = Library.list_series(user_scope_fixture(admin_user_fixture()))
    {:ok, show_lv, html} = live(conn, ~p"/series/#{series.id}")
    assert html =~ "Uma Aventura"
    assert has_element?(show_lv, "#series-book-#{b1.id}")
    assert has_element?(show_lv, "#series-book-#{b2.id}")
  end

  describe "adding books on the show page" do
    setup %{conn: conn} do
      scope = user_scope_fixture(admin_user_fixture())
      library = library_fixture()
      seed = book_fixture(%{library: library, title: "Book One"})
      Library.set_book_series(seed, [%{name: "Uma Aventura", sequence: "1"}])
      [series] = Library.list_series(scope)

      %{conn: conn, scope: scope, library: library, series: series}
    end

    test "searches for and adds a book with a sequence", ctx do
      book = book_fixture(%{library: ctx.library, title: "Searchable Sequel"})

      {:ok, lv, _html} = live(ctx.conn, ~p"/series/#{ctx.series.id}")

      html =
        lv
        |> form("#series-add-form", %{"query" => "Searchable"})
        |> render_change()

      assert html =~ "Searchable Sequel"

      lv
      |> form("#add-book-form-#{book.id}", %{"book-id" => book.id, "sequence" => "2"})
      |> render_submit()

      assert has_element?(lv, "#series-book-#{book.id}")
      refute has_element?(lv, "#add-result-#{book.id}")

      loaded = Library.get_series(ctx.scope, ctx.series.id)
      entries = Enum.map(loaded.book_series, &{&1.book.title, &1.sequence})
      assert {"Searchable Sequel", "2"} in entries
    end

    test "shows an error when adding without a sequence", ctx do
      book = book_fixture(%{library: ctx.library, title: "No Seq Book"})

      {:ok, lv, _html} = live(ctx.conn, ~p"/series/#{ctx.series.id}")
      lv |> form("#series-add-form", %{"query" => "No Seq"}) |> render_change()

      html =
        lv
        |> form("#add-book-form-#{book.id}", %{"book-id" => book.id, "sequence" => ""})
        |> render_submit()

      assert html =~ "Enter a sequence number"
      refute has_element?(lv, "#series-book-#{book.id}")
    end

    test "removes a book from the series", ctx do
      book = book_fixture(%{library: ctx.library, title: "Removable"})
      {:ok, _} = Library.add_book_to_series(ctx.scope, ctx.series.id, book.id, "3")

      {:ok, lv, _html} = live(ctx.conn, ~p"/series/#{ctx.series.id}")
      assert has_element?(lv, "#series-book-#{book.id}")

      lv
      |> element(~s|button[phx-click=remove_book][phx-value-book-id="#{book.id}"]|)
      |> render_click()

      refute has_element?(lv, "#series-book-#{book.id}")
    end
  end
end
