defmodule PagelessWeb.API.ListeningHistoryControllerTest do
  use PagelessWeb.ConnCase, async: true

  import Pageless.AccountsFixtures
  import Pageless.LibraryFixtures

  alias Pageless.Accounts
  alias Pageless.Playback.{ListeningEvent, ListeningSession}
  alias Pageless.Repo

  setup %{conn: conn} do
    user = set_password(user_fixture())
    {:ok, {token, _}} = Accounts.create_api_token(user.email, valid_user_password(), "test")

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn, user: user}
  end

  test "POST /api/listening-history upserts sessions and events", %{conn: conn, user: user} do
    book = book_fixture(%{duration_seconds: 1000.0})
    session_id = Ecto.UUID.generate()
    event_id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    conn =
      post(conn, ~p"/api/listening-history", %{
        sessions: [
          %{
            id: session_id,
            book_id: book.id,
            title: book.title,
            authors: "Author",
            play_method: "Local",
            device_info: "Android\nPixel",
            started_at: now,
            updated_at: now,
            ended_at: nil,
            time_listened_seconds: 15,
            last_position_seconds: 123.0,
            duration_seconds: 1000.0
          }
        ],
        events: [
          %{
            id: event_id,
            session_id: session_id,
            book_id: book.id,
            event: "Play",
            type: "Playback",
            position_seconds: 123.0,
            timestamp: now,
            server_sync_attempted: false
          }
        ]
      })

    assert %{"history" => %{"ok" => true}} = json_response(conn, 200)

    assert %ListeningSession{user_id: user_id, book_id: book_id, time_listened_seconds: 15} =
             Repo.get(ListeningSession, session_id)

    assert user_id == user.id
    assert book_id == book.id

    assert %ListeningEvent{event: "Play", position_seconds: 123.0} =
             Repo.get(ListeningEvent, event_id)
  end
end
