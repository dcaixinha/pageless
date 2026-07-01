defmodule PagelessWeb.API.CollectionController do
  use PagelessWeb, :controller

  alias Pageless.Library
  alias PagelessWeb.API.ApiJSON

  action_fallback PagelessWeb.API.FallbackController

  def index(conn, _params) do
    collections =
      Enum.map(Library.list_collections(conn.assigns.current_scope), &ApiJSON.collection/1)

    json(conn, %{collections: collections})
  end

  def show(conn, %{"id" => id}) do
    case Library.get_collection(conn.assigns.current_scope, id) do
      nil -> {:error, :not_found}
      collection -> json(conn, %{collection: ApiJSON.collection_detail(collection)})
    end
  end
end
