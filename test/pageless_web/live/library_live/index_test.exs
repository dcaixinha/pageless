defmodule PagelessWeb.LibraryLive.IndexTest do
  use PagelessWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Pageless.AccountsFixtures
  import Pageless.LibraryFixtures

  alias Pageless.Library
  alias Pageless.Repo

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), scope: user_scope_fixture(user)}
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/library")
  end

  test "renders empty state when no books", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/library")
    assert html =~ "No books found"
  end

  test "lists books in the grid", %{conn: conn} do
    library = library_fixture()
    book_fixture(%{library: library, title: "The Hobbit"})

    {:ok, lv, _html} = live(conn, ~p"/library")
    assert has_element?(lv, "#library-grid")
    assert render(lv) =~ "The Hobbit"
  end

  test "refreshes the current filtered catalog when a scan changes books", %{conn: conn} do
    library = library_fixture()
    existing = book_fixture(%{library: library, title: "Matching Existing"})

    {:ok, lv, _html} = live(conn, ~p"/library?#{%{"search" => "matching"}}")
    assert has_element?(lv, "#library-grid a[href='/books/#{existing.id}']")

    added = book_fixture(%{library: library, title: "Matching Added"})
    Pageless.Library.Events.broadcast_changed(library.id, [added.id], [])

    assert has_element?(lv, "#library-grid a[href='/books/#{added.id}']")
    assert has_element?(lv, "#library-search-form input[value='matching']")
  end

  test "search filters books", %{conn: conn} do
    library = library_fixture()
    book_fixture(%{library: library, title: "The Hobbit"})
    book_fixture(%{library: library, title: "Dune"})

    {:ok, lv, _html} = live(conn, ~p"/library")

    html =
      lv
      |> form("form[phx-change=search]", %{"search" => "hobbit"})
      |> render_change()

    assert html =~ "The Hobbit"
    refute html =~ "Dune"
  end

  test "search presents grouped books and filterable metadata", %{conn: conn, scope: scope} do
    library = library_fixture(name: "Alpha Library")
    book = book_fixture(%{library: library, title: "Matched Book", language: "Alpha Language"})
    author = Library.upsert_author("Alpha Author")
    narrator = Library.upsert_narrator("Alpha Narrator")
    genre = Library.upsert_genre("Alpha Genre")
    publisher = Library.upsert_publisher("Alpha Publisher")
    series = Library.upsert_series("Alpha Series")
    collection = Library.upsert_collection(library.id, "Alpha Collection")
    {:ok, playlist} = Library.create_playlist(scope, "Alpha Playlist")

    book |> attach_author(author) |> attach_genre(genre)
    {:ok, :ok} = Library.replace_book_narrators(book, [narrator.name])
    {:ok, _book} = Library.update_book(book, %{"publisher" => publisher.name})
    Library.set_book_series(book, [%{name: series.name, sequence: "1"}])
    {:ok, _collection} = Library.add_book_to_collection(scope, collection.id, book.id)
    {:ok, _playlist} = Library.add_book_to_playlist(scope, playlist.id, book.id)

    {:ok, lv, _html} = live(conn, ~p"/library")

    lv |> form("#library-search-form", %{"search" => "a"}) |> render_change()
    refute has_element?(lv, "#library-search-results")

    lv |> form("#library-search-form", %{"search" => "alpha"}) |> render_change()

    assert has_element?(lv, "#search-result-book-#{book.id}[href='/books/#{book.id}']")
    assert_search_result(lv, :authors, author.id, ~p"/library?#{%{"authors" => [author.id]}}")

    assert_search_result(
      lv,
      :narrators,
      narrator.id,
      ~p"/library?#{%{"narrators" => [narrator.id]}}"
    )

    assert_search_result(lv, :series, series.id, ~p"/library?#{%{"series" => [series.id]}}")

    assert_search_result(
      lv,
      :collections,
      collection.id,
      ~p"/library?#{%{"collections" => [collection.id]}}"
    )

    assert_search_result(
      lv,
      :playlists,
      playlist.id,
      ~p"/library?#{%{"playlists" => [playlist.id]}}"
    )

    assert_search_result(lv, :genres, genre.id, ~p"/library?#{%{"genres" => [genre.id]}}")

    assert_search_result(
      lv,
      :publishers,
      publisher.id,
      ~p"/library?#{%{"publishers" => [publisher.id]}}"
    )

    assert has_element?(
             lv,
             "#search-group-languages a[href='#{~p"/library?#{%{"languages" => ["Alpha Language"]}}"}']"
           )

    assert_search_result(
      lv,
      :libraries,
      library.id,
      ~p"/library?#{%{"libraries" => [library.id]}}"
    )

    assert has_element?(lv, "#search-result-authors-#{author.id}", "1 book")

    lv |> element("#clear-library-search") |> render_click()
    assert_patch(lv, ~p"/library")
    refute has_element?(lv, "#library-search-results")
  end

  test "facet search results preserve the current sort", %{conn: conn} do
    book = book_fixture(%{title: "Matched"})
    author = Library.upsert_author("Alpha Author")
    attach_author(book, author)

    {:ok, lv, _html} = live(conn, ~p"/library?#{%{"sort" => "duration"}}")
    lv |> form("#library-search-form", %{"search" => "alpha"}) |> render_change()

    expected = ~p"/library?#{%{"authors" => [author.id], "sort" => "duration"}}"
    assert has_element?(lv, "#search-result-authors-#{author.id}[href='#{expected}']")
  end

  test "selects a sort and reverses its direction", %{conn: conn} do
    library = library_fixture()
    book_fixture(%{library: library, title: "Short", duration_seconds: 100.0})
    book_fixture(%{library: library, title: "Long", duration_seconds: 900.0})

    {:ok, lv, _html} = live(conn, ~p"/library")

    lv |> element("#library-sort-button") |> render_click()
    assert has_element?(lv, "#library-sort-panel")
    assert has_element?(lv, "#sort-option-author_first")
    assert has_element?(lv, "#sort-option-author_last")
    assert has_element?(lv, "#sort-option-published")
    assert has_element?(lv, "#sort-option-size")
    assert has_element?(lv, "#sort-option-modified")
    assert has_element?(lv, "#sort-option-progress_updated")
    assert has_element?(lv, "#sort-option-progress_started")
    assert has_element?(lv, "#sort-option-progress_finished")
    assert has_element?(lv, "#sort-option-random")

    lv |> element("#sort-option-duration") |> render_click()
    assert_patch(lv, ~p"/library?#{%{"sort" => "duration"}}")
    assert has_element?(lv, "#library-sort-button", "Duration")

    lv |> element("#library-sort-button") |> render_click()
    lv |> element("#sort-direction-toggle") |> render_click()

    assert_patch(lv, ~p"/library?#{%{"sort" => "duration", "direction" => "asc"}}")
    assert has_element?(lv, "#sort-direction-toggle", "Ascending")

    lv |> element("#sort-option-duration") |> render_click()
    assert_patch(lv, ~p"/library?#{%{"sort" => "duration"}}")
    refute has_element?(lv, "#library-sort-panel")

    lv |> element("#library-sort-button") |> render_click()
    lv |> element("#sort-option-random") |> render_click()
    assert_patch(lv, ~p"/library?#{%{"sort" => "random"}}")

    lv |> element("#library-sort-button") |> render_click()
    refute has_element?(lv, "#sort-direction-toggle")
  end

  test "opens filters and patches selected facets into the URL", %{conn: conn} do
    library = library_fixture()
    author = Library.upsert_author("Ursula K. Le Guin")

    matching =
      book_fixture(%{library: library, title: "A Wizard of Earthsea"}) |> attach_author(author)

    other = book_fixture(%{library: library, title: "The Dispossessed"})

    {:ok, lv, _html} = live(conn, ~p"/library")

    lv |> element("#library-filters-button") |> render_click()
    assert has_element?(lv, "#library-filter-panel")
    assert has_element?(lv, "#filter-option-authors-#{author.id}")

    lv |> element("#filter-option-authors-#{author.id}") |> render_click()
    assert_patch(lv, ~p"/library?#{%{"authors" => [author.id]}}")

    assert has_element?(lv, "#library-filter-count", "1")
    assert has_element?(lv, "#active-filter-authors-#{author.id}")
    assert has_element?(lv, "#library-grid a[href='/books/#{matching.id}']")
    refute has_element?(lv, "#library-grid a[href='/books/#{other.id}']")

    lv |> element("#filter-option-authors-#{author.id}") |> render_click()
    assert_patch(lv, ~p"/library")
    refute has_element?(lv, "#active-library-filters")
  end

  test "filters books by narrator", %{conn: conn} do
    library = library_fixture()
    matching = book_fixture(%{library: library, title: "Narrated Book"})
    other = book_fixture(%{library: library, title: "Other Book"})
    narrator = Library.upsert_narrator("Andy Serkis")
    {:ok, :ok} = Library.replace_book_narrators(matching, [narrator.name])

    {:ok, lv, _html} = live(conn, ~p"/library")
    lv |> element("#library-filters-button") |> render_click()
    lv |> element("#filter-category-narrators") |> render_click()
    lv |> element("#filter-option-narrators-#{narrator.id}") |> render_click()

    assert_patch(lv, ~p"/library?#{%{"narrators" => [narrator.id]}}")
    assert has_element?(lv, "#library-grid a[href='/books/#{matching.id}']")
    refute has_element?(lv, "#library-grid a[href='/books/#{other.id}']")
  end

  test "filters books by publisher", %{conn: conn} do
    library = library_fixture()
    matching = book_fixture(%{library: library, title: "Published Book"})
    other = book_fixture(%{library: library, title: "Other Book"})
    publisher = Library.upsert_publisher("Pageless Press")
    {:ok, _book} = Library.update_book(matching, %{"publisher" => publisher.name})

    {:ok, lv, _html} = live(conn, ~p"/library")
    lv |> element("#library-filters-button") |> render_click()
    lv |> element("#filter-category-publishers") |> render_click()
    lv |> element("#filter-option-publishers-#{publisher.id}") |> render_click()

    assert_patch(lv, ~p"/library?#{%{"publishers" => [publisher.id]}}")
    assert has_element?(lv, "#library-grid a[href='/books/#{matching.id}']")
    refute has_element?(lv, "#library-grid a[href='/books/#{other.id}']")
  end

  test "filters books by language", %{conn: conn} do
    library = library_fixture()
    matching = book_fixture(%{library: library, title: "English Book", language: "English"})
    other = book_fixture(%{library: library, title: "Portuguese Book", language: "Portuguese"})

    {:ok, lv, _html} = live(conn, ~p"/library")
    lv |> element("#library-filters-button") |> render_click()
    lv |> element("#filter-category-languages") |> render_click()
    lv |> element("#filter-option-languages-RW5nbGlzaA") |> render_click()

    assert_patch(lv, ~p"/library?#{%{"languages" => ["English"]}}")
    assert has_element?(lv, "#library-grid a[href='/books/#{matching.id}']")
    refute has_element?(lv, "#library-grid a[href='/books/#{other.id}']")
  end

  test "restores combined filters from the URL and ignores invalid values", %{conn: conn} do
    library = library_fixture(name: "Main library")
    genre = Library.upsert_genre("Science Fiction")
    matching = book_fixture(%{library: library, title: "Dune"}) |> attach_genre(genre)
    other = book_fixture(%{library: library, title: "Earthsea"})

    path =
      ~p"/library?#{%{"genres" => [genre.id, genre.id], "libraries" => [library.id, "invalid"]}}"

    {:ok, lv, _html} = live(conn, path)

    assert has_element?(lv, "#library-filter-count", "2")
    assert has_element?(lv, "#active-filter-genres-#{genre.id}")
    assert has_element?(lv, "#active-filter-libraries-#{library.id}")
    assert has_element?(lv, "#library-grid a[href='/books/#{matching.id}']")
    refute has_element?(lv, "#library-grid a[href='/books/#{other.id}']")
  end

  test "ignores malformed search parameters", %{conn: conn} do
    library = library_fixture()
    book = book_fixture(%{library: library})

    {:ok, lv, _html} = live(conn, ~p"/library?#{%{"search" => %{"invalid" => "value"}}}")

    assert has_element?(lv, "#library-grid a[href='/books/#{book.id}']")
  end

  defp attach_author(book, author), do: attach(book, :authors, author)
  defp attach_genre(book, genre), do: attach(book, :genres, genre)

  defp assert_search_result(lv, category, id, href) do
    assert has_element?(lv, "#search-result-#{category}-#{id}[href='#{href}']")
  end

  defp attach(book, association, entity) do
    book
    |> Repo.preload(association)
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(association, [entity])
    |> Repo.update!()
  end
end
