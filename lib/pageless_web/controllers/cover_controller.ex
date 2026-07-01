defmodule PagelessWeb.CoverController do
  use PagelessWeb, :controller

  alias Pageless.Library

  @doc """
  Serves a book's cover image from the configured media directory.

  Falls back to a 404 when the book has no cover on disk.
  """
  def show(conn, %{"id" => id}) do
    with %{cover_path: path} when is_binary(path) <-
           Library.get_book(conn.assigns.current_scope, id),
         true <- File.exists?(path) do
      conn
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> put_resp_content_type(content_type(path))
      |> send_file(200, path)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  defp content_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      _ -> "image/jpeg"
    end
  end
end
