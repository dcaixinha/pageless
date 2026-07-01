defmodule PagelessWeb.API.MeController do
  use PagelessWeb, :controller

  alias PagelessWeb.API.ApiJSON

  @doc """
  Returns the authenticated user plus the server version, for the mobile
  Account screen.
  """
  def show(conn, _params) do
    user = conn.assigns.current_scope.user

    json(conn, %{
      user: ApiJSON.user(user),
      server_version: server_version()
    })
  end

  defp server_version do
    System.get_env("PAGELESS_VERSION") || app_version()
  end

  defp app_version do
    case Application.spec(:pageless, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end
end
