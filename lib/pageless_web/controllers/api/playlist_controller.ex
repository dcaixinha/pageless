defmodule PagelessWeb.API.PlaylistController do
  use PagelessWeb, :controller

  alias Pageless.Library
  alias PagelessWeb.API.ApiJSON

  action_fallback PagelessWeb.API.FallbackController

  def index(conn, _params) do
    playlists =
      Enum.map(Library.list_playlists(conn.assigns.current_scope), &ApiJSON.playlist/1)

    json(conn, %{playlists: playlists})
  end

  def show(conn, %{"id" => id}) do
    case Library.get_playlist(conn.assigns.current_scope, id) do
      nil -> {:error, :not_found}
      playlist -> json(conn, %{playlist: ApiJSON.playlist_detail(playlist)})
    end
  end
end
