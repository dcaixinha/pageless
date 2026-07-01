defmodule PagelessWeb.ApiAuth do
  @moduledoc """
  Authentication plugs for the JSON API used by mobile clients.

  Clients authenticate with a long-lived bearer token obtained from
  `POST /api/session`. The token is sent in the `Authorization: Bearer <token>`
  header. On success the connection's `:current_scope` is assigned, mirroring
  the browser session flow, and the raw token is stashed in `:api_token` so the
  logout endpoint can revoke it.
  """

  import Plug.Conn

  alias Pageless.Accounts
  alias Pageless.Accounts.Scope

  @doc """
  Assigns `:current_scope` from a bearer token when present and valid.

  Never halts — pair with `require_api_user/2` for endpoints that must be
  authenticated.
  """
  def fetch_api_user(conn, _opts) do
    with token when is_binary(token) <- bearer_token(conn),
         %Accounts.User{} = user <- Accounts.get_user_by_api_token(token) do
      conn
      |> assign(:current_scope, Scope.for_user(user))
      |> assign(:api_token, token)
    else
      _ ->
        conn
        |> assign(:current_scope, Scope.for_user(nil))
        |> assign(:api_token, nil)
    end
  end

  @doc """
  Halts with `401` unless a user was resolved by `fetch_api_user/2`.
  """
  def require_api_user(conn, _opts) do
    if conn.assigns[:current_scope] && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
      |> halt()
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> String.trim(token)
      _ -> nil
    end
  end
end
