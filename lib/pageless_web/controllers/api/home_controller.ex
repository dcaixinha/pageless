defmodule PagelessWeb.API.HomeController do
  use PagelessWeb, :controller

  alias Pageless.Library
  alias Pageless.Playback
  alias PagelessWeb.API.ApiJSON

  @doc """
  Returns the home shelves for the scoped user:

    * `continue_listening` - started, not finished (most recent first)
    * `discover` - recently added, excluding anything already started/finished
    * `listen_again` - finished books (most recently finished first)

  Each entry is a book summary, with progress embedded where relevant.
  """
  def index(conn, _params) do
    scope = conn.assigns.current_scope

    continue = Enum.map(Playback.continue_listening(scope), &book_with_progress/1)
    listen_again = Enum.map(Playback.finished_books(scope), &book_with_progress/1)

    seen_ids = MapSet.new(Playback.book_ids_with_progress(scope))

    discover =
      Library.recently_added(scope, 12)
      |> Enum.reject(&MapSet.member?(seen_ids, &1.id))
      |> Enum.map(&ApiJSON.book_summary/1)

    json(conn, %{
      continue_listening: continue,
      discover: discover,
      listen_again: listen_again
    })
  end

  defp book_with_progress({book, progress}) do
    book
    |> ApiJSON.book_summary()
    |> Map.put(:progress, progress && ApiJSON.progress(progress))
  end
end
