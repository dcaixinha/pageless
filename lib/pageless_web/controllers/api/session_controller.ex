defmodule PagelessWeb.API.SessionController do
  use PagelessWeb, :controller

  alias Pageless.Accounts
  alias PagelessWeb.API.ApiJSON

  action_fallback PagelessWeb.API.FallbackController

  @doc """
  Authenticates with email/password and returns a long-lived API token.

  Body: `{"email": ..., "password": ..., "device_name": ...}`
  """
  def create(conn, %{"email" => email, "password" => password} = params)
      when is_binary(email) and is_binary(password) do
    device_name = params["device_name"] || "mobile device"

    case Accounts.create_api_token(email, password, device_name) do
      {:ok, {token, user}} ->
        conn
        |> put_status(:created)
        |> json(%{token: token, user: ApiJSON.user(user)})

      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid credentials"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "email and password are required"})
  end

  @doc "Revokes the current API token."
  def delete(conn, _params) do
    Accounts.delete_api_token(conn.assigns[:api_token])
    send_resp(conn, :no_content, "")
  end
end
