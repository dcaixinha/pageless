defmodule PagelessWeb.API.ListeningHistoryController do
  use PagelessWeb, :controller

  alias Pageless.Playback
  alias PagelessWeb.API.ApiJSON

  action_fallback PagelessWeb.API.FallbackController

  @doc "Pushes client-captured listening sessions/events in a retry-safe batch."
  def create(conn, params) do
    sessions = params["sessions"] || []
    events = params["events"] || []

    with {:ok, :ok} <-
           Playback.upsert_listening_history(conn.assigns.current_scope, sessions, events) do
      json(conn, %{history: ApiJSON.listening_history_ack()})
    end
  end
end
