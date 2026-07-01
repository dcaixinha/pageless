defmodule PagelessWeb.API.BookController do
  use PagelessWeb, :controller

  alias Pageless.Accounts
  alias Pageless.Library
  alias Pageless.Playback
  alias PagelessWeb.API.ApiJSON
  alias PagelessWeb.RangeFile

  action_fallback PagelessWeb.API.FallbackController

  @sorts %{"title" => :title, "added" => :added, "duration" => :duration}

  def index(conn, params) do
    opts =
      [
        library_id: params["library_id"],
        search: params["search"],
        sort: @sorts[params["sort"]]
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    books =
      Enum.map(Library.list_books(conn.assigns.current_scope, opts), &ApiJSON.book_summary/1)

    json(conn, %{books: books})
  end

  def show(conn, %{"id" => id}) do
    case Library.get_book(conn.assigns.current_scope, id) do
      nil ->
        {:error, :not_found}

      book ->
        progress = Playback.get_progress(conn.assigns.current_scope, book.id)
        json(conn, %{book: ApiJSON.book_detail(book, progress)})
    end
  end

  @doc "Streams the book's audio file for offline download (Range-capable)."
  def download(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user

    with true <- Accounts.user_can?(user, :can_download),
         %{audio_files: [audio | _]} <- Library.get_book(conn.assigns.current_scope, id),
         true <- File.exists?(audio.path) do
      RangeFile.send(conn, audio.path, audio.mime_type || "audio/mp4")
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Serves the book's cover image (authenticated for mobile clients)."
  def cover(conn, %{"id" => id}) do
    with %{cover_path: path} when is_binary(path) <-
           Library.get_book(conn.assigns.current_scope, id),
         true <- File.exists?(path) do
      conn
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> put_resp_content_type(cover_content_type(path))
      |> send_file(200, path)
    else
      _ -> {:error, :not_found}
    end
  end

  defp cover_content_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      _ -> "image/jpeg"
    end
  end
end
