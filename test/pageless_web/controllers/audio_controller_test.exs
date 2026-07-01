defmodule PagelessWeb.AudioControllerTest do
  use PagelessWeb.ConnCase, async: true

  import Pageless.AccountsFixtures
  import Pageless.LibraryFixtures

  @m4b Path.expand("../../support/fixtures/media/The Test Book/The Test Book.m4b", __DIR__)

  setup do
    book = book_fixture(%{duration_seconds: 6.0})
    audio_file_fixture(book, %{path: @m4b, mime_type: "audio/mp4"})
    %{book: book}
  end

  test "requires authentication or token", %{conn: conn, book: book} do
    conn = get(conn, ~p"/books/#{book.id}/audio")
    assert conn.status in [302, 404]
  end

  test "streams full file for authenticated user", %{conn: conn, book: book} do
    user = user_fixture()
    conn = conn |> log_in_user(user) |> get(~p"/books/#{book.id}/audio")

    assert conn.status == 200
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
  end

  test "honors range requests with a 206 response", %{conn: conn, book: book} do
    user = user_fixture()

    conn =
      conn
      |> log_in_user(user)
      |> put_req_header("range", "bytes=0-99")
      |> get(~p"/books/#{book.id}/audio")

    assert conn.status == 206
    assert [content_range] = get_resp_header(conn, "content-range")
    assert content_range =~ "bytes 0-99/"
    assert byte_size(conn.resp_body) == 100
  end

  test "accepts a signed token without a session", %{conn: conn, book: book} do
    user = user_fixture()
    token = PagelessWeb.AudioController.sign_token(PagelessWeb.Endpoint, user.id, book.id)

    conn = get(conn, ~p"/books/#{book.id}/audio?token=#{token}")
    assert conn.status == 200
  end
end
