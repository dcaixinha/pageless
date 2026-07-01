defmodule PagelessWeb.API.ProgressController do
  use PagelessWeb, :controller

  alias Pageless.Playback
  alias PagelessWeb.API.ApiJSON

  action_fallback PagelessWeb.API.FallbackController

  @doc """
  Pulls progress records changed since `?since=<iso8601>` (all if omitted),
  oldest first, for the authenticated user.
  """
  def index(conn, params) do
    since = parse_since(params["since"])
    records = Playback.changes_since(conn.assigns.current_scope, since)
    json(conn, %{progress: Enum.map(records, &ApiJSON.progress/1)})
  end

  @doc """
  Optimistically pushes a progress update for a book (last-write-wins by
  `last_played_at`).

  Body: `{"current_seconds": ..., "duration_seconds": ..., "last_played_at": iso8601}`
  """
  def update(conn, %{"book_id" => book_id} = params) do
    attrs = %{
      current_seconds: params["current_seconds"],
      duration_seconds: params["duration_seconds"],
      last_played_at: params["last_played_at"]
    }

    with {:ok, progress} <- Playback.upsert_progress(conn.assigns.current_scope, book_id, attrs) do
      json(conn, %{progress: ApiJSON.progress(progress)})
    end
  end

  defp parse_since(nil), do: nil

  defp parse_since(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
