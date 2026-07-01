defmodule PagelessWeb.API.LibraryController do
  use PagelessWeb, :controller

  alias Pageless.Library
  alias PagelessWeb.API.ApiJSON

  def index(conn, _params) do
    libraries = Enum.map(Library.list_libraries(conn.assigns.current_scope), &ApiJSON.library/1)
    json(conn, %{libraries: libraries})
  end
end
