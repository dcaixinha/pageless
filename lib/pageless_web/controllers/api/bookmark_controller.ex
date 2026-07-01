defmodule PagelessWeb.API.BookmarkController do
  use PagelessWeb, :controller

  alias Pageless.Playback
  alias PagelessWeb.API.ApiJSON

  action_fallback PagelessWeb.API.FallbackController

  @doc "Lists bookmarks for a specific book (ordered by position)."
  def index_for_book(conn, %{"book_id" => book_id}) do
    bookmarks = Playback.list_bookmarks(conn.assigns.current_scope, book_id)
    json(conn, %{bookmarks: Enum.map(bookmarks, &ApiJSON.bookmark/1)})
  end

  @doc "Pulls all of the user's bookmarks changed since `?since=<iso8601>`."
  def index(conn, params) do
    since = parse_since(params["since"])
    bookmarks = Playback.list_all_bookmarks(conn.assigns.current_scope, since)
    json(conn, %{bookmarks: Enum.map(bookmarks, &ApiJSON.bookmark/1)})
  end

  @doc """
  Idempotently creates/updates a bookmark with a client-supplied id.

  Body: `{"book_id": ..., "position_seconds": ..., "note": ...}`
  """
  def update(conn, %{"id" => id, "book_id" => book_id} = params) do
    with {:ok, bookmark} <-
           Playback.upsert_bookmark(
             conn.assigns.current_scope,
             id,
             book_id,
             params["position_seconds"],
             params["note"]
           ) do
      json(conn, %{bookmark: ApiJSON.bookmark(bookmark)})
    end
  end

  def delete(conn, %{"id" => id}) do
    Playback.delete_bookmark(conn.assigns.current_scope, id)
    send_resp(conn, :no_content, "")
  end

  defp parse_since(nil), do: nil

  defp parse_since(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
