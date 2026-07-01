defmodule PagelessWeb.API.SeriesController do
  use PagelessWeb, :controller

  alias Pageless.Library
  alias PagelessWeb.API.ApiJSON

  action_fallback PagelessWeb.API.FallbackController

  def index(conn, _params) do
    series = Enum.map(Library.list_series(conn.assigns.current_scope), &ApiJSON.series_summary/1)
    json(conn, %{series: series})
  end

  def show(conn, %{"id" => id}) do
    case Library.get_series(conn.assigns.current_scope, id) do
      nil -> {:error, :not_found}
      series -> json(conn, %{series: ApiJSON.series_detail(series)})
    end
  end
end
