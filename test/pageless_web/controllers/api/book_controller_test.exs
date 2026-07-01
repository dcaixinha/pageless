defmodule PagelessWeb.API.BookControllerTest do
  use PagelessWeb.ConnCase, async: true

  import Pageless.AccountsFixtures
  import Pageless.LibraryFixtures

  alias Pageless.Accounts
  alias Pageless.{Library, Playback}

  setup %{conn: conn} do
    user = set_password(user_fixture())
    {:ok, {token, _}} = Accounts.create_api_token(user.email, valid_user_password(), "test")

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn, user: user, scope: user_scope_fixture(user)}
  end

  test "unauthenticated requests are rejected", %{} do
    conn = build_conn() |> put_req_header("accept", "application/json")
    conn = get(conn, ~p"/api/books")
    assert json_response(conn, 401)
  end

  test "GET /api/books lists book summaries", %{conn: conn, scope: scope} do
    book =
      book_fixture(%{
        title: "The Hobbit",
        size: 1234,
        mtime: ~U[2024-01-01 00:00:00Z],
        language: "English"
      })

    {:ok, :ok} = Library.replace_book_narrators(book, ["Andy Serkis", "Doe, Jane"])
    {:ok, book} = Library.update_book(book, %{"publisher" => "HarperCollins"})
    Library.set_book_series(book, [%{name: "Middle-earth", sequence: "1"}])
    [series] = Library.list_series(scope)
    conn = get(conn, ~p"/api/books")
    assert %{"books" => books} = json_response(conn, 200)

    summary = Enum.find(books, &(&1["id"] == book.id))
    assert summary["title"] == "The Hobbit"
    assert Enum.map(summary["narrators"], & &1["name"]) == ["Andy Serkis", "Doe, Jane"]
    assert summary["series"] == [%{"id" => series.id, "name" => "Middle-earth"}]
    assert summary["publisher"] == %{"id" => book.publisher.id, "name" => "HarperCollins"}
    assert summary["language"] == "English"
    assert summary["size"] == 1234
    assert summary["added_at"]
    assert summary["file_modified"] == "2024-01-01T00:00:00Z"
    refute Map.has_key?(summary, "narrator")
  end

  test "GET /api/books applies the user's title prefix preference", %{conn: conn, user: user} do
    assert {:ok, _user} =
             Accounts.update_player_settings(user, %{"ignore_prefixes_when_sorting" => true})

    library = library_fixture()
    book_fixture(%{library: library, title: "The Apple"})
    book_fixture(%{library: library, title: "Banana"})

    body = json_response(get(conn, ~p"/api/books?sort=title"), 200)
    assert Enum.map(body["books"], & &1["title"]) == ["The Apple", "Banana"]
  end

  test "GET /api/books/:id returns detail with chapters and progress", %{
    conn: conn,
    scope: scope
  } do
    book = book_fixture(%{title: "Dune", duration_seconds: 1000.0})
    chapter_fixture(book, %{title: "Ch1", start_seconds: 0.0, end_seconds: 500.0, index: 0})
    Playback.save_progress(scope, book.id, 300.0, 1000.0)

    conn = get(conn, ~p"/api/books/#{book.id}")
    assert %{"book" => detail} = json_response(conn, 200)
    assert detail["title"] == "Dune"
    assert [%{"title" => "Ch1"}] = detail["chapters"]
    assert detail["progress"]["current_seconds"] == 300.0
  end

  test "GET /api/books/:id returns 404 for unknown book", %{conn: conn} do
    conn = get(conn, ~p"/api/books/#{Ecto.UUID.generate()}")
    assert json_response(conn, 404)
  end

  test "GET /api/books/:id/download 404s when the file is missing", %{conn: conn} do
    book = book_fixture()
    audio_file_fixture(book, %{path: "/nonexistent/file.m4b"})
    conn = get(conn, ~p"/api/books/#{book.id}/download")
    assert json_response(conn, 404)
  end

  test "GET /api/books/:id/download serves the file with range support", %{conn: conn} do
    book = book_fixture()
    path = Path.join(System.tmp_dir!(), "pageless_test_#{System.unique_integer([:positive])}.m4b")
    File.write!(path, "0123456789")
    on_exit(fn -> File.rm(path) end)
    audio_file_fixture(book, %{path: path, mime_type: "audio/mp4"})

    conn = get(conn, ~p"/api/books/#{book.id}/download")
    assert response(conn, 200) == "0123456789"
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
  end

  test "GET /api/books/:id/cover 404s when there is no cover", %{conn: conn} do
    book = book_fixture()
    conn = get(conn, ~p"/api/books/#{book.id}/cover")
    assert json_response(conn, 404)
  end

  test "GET /api/books/:id/cover serves the image when present", %{conn: conn} do
    path =
      Path.join(System.tmp_dir!(), "pageless_cover_#{System.unique_integer([:positive])}.jpg")

    File.write!(path, "jpegbytes")
    on_exit(fn -> File.rm(path) end)
    book = book_fixture(%{cover_path: path})

    conn = get(conn, ~p"/api/books/#{book.id}/cover")
    assert response(conn, 200) == "jpegbytes"
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/jpeg"
  end

  test "book detail exposes has_cover", %{conn: conn} do
    book = book_fixture(%{cover_path: "/some/cover.jpg"})
    conn = get(conn, ~p"/api/books/#{book.id}")
    assert json_response(conn, 200)["book"]["has_cover"] == true
  end

  test "book detail exposes genres", %{conn: conn} do
    book = book_fixture(%{title: "Genres"})
    {:ok, book} = Pageless.Library.update_book(book, %{"genres" => "History, Science"})

    conn = get(conn, ~p"/api/books/#{book.id}")

    assert [%{"name" => "History"}, %{"name" => "Science"}] =
             json_response(conn, 200)["book"]["genres"]
  end

  test "book detail exposes series with id, name and sequence", %{conn: conn} do
    book = book_fixture(%{title: "In A Series"})
    {:ok, book} = Pageless.Library.update_book(book, %{"series" => "Foundation #2"})

    conn = get(conn, ~p"/api/books/#{book.id}")

    assert [%{"id" => series_id, "name" => "Foundation", "sequence" => "2"}] =
             json_response(conn, 200)["book"]["series"]

    assert is_binary(series_id)
  end
end
