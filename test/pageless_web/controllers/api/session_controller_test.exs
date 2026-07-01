defmodule PagelessWeb.API.SessionControllerTest do
  use PagelessWeb.ConnCase, async: true

  import Pageless.AccountsFixtures

  alias Pageless.Accounts

  setup %{conn: conn} do
    user = set_password(user_fixture())
    %{conn: put_req_header(conn, "accept", "application/json"), user: user}
  end

  describe "POST /api/session" do
    test "returns a token for valid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/api/session", %{
          email: user.email,
          password: valid_user_password(),
          device_name: "Pixel 8"
        })

      assert %{
               "token" => token,
               "user" => %{
                 "email" => email,
                 "date_format" => "dd/MM/yyyy",
                 "time_format" => "HH:mm"
               }
             } = json_response(conn, 201)

      assert email == user.email
      assert is_binary(token) and token != ""
      # Token actually authenticates.
      assert %Accounts.User{id: id} = Accounts.get_user_by_api_token(token)
      assert id == user.id
    end

    test "rejects invalid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/api/session", %{email: user.email, password: "wrong password"})

      assert json_response(conn, 401)["error"] =~ "invalid"
    end

    test "requires email and password", %{conn: conn} do
      conn = post(conn, ~p"/api/session", %{email: "x@example.com"})
      assert json_response(conn, 400)
    end
  end

  describe "DELETE /api/session" do
    test "revokes the token", %{conn: conn, user: user} do
      {:ok, {token, _user}} =
        Accounts.create_api_token(user.email, valid_user_password(), "Pixel 8")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> delete(~p"/api/session")

      assert response(conn, 204)
      assert Accounts.get_user_by_api_token(token) == nil
    end

    test "requires authentication", %{conn: conn} do
      conn = delete(conn, ~p"/api/session")
      assert json_response(conn, 401)
    end
  end
end
