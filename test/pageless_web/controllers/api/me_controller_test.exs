defmodule PagelessWeb.API.MeControllerTest do
  use PagelessWeb.ConnCase, async: false

  import Pageless.AccountsFixtures

  alias Pageless.Accounts

  setup %{conn: conn} do
    user = set_password(user_fixture())
    {:ok, {token, _}} = Accounts.create_api_token(user.email, valid_user_password(), "test")

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn, user: user}
  end

  test "returns the user and server version", %{conn: conn, user: user} do
    body = json_response(get(conn, ~p"/api/me"), 200)
    assert body["user"]["email"] == user.email
    assert body["user"]["ignore_prefixes_when_sorting"] == false
    assert body["user"]["date_format"] == "dd/MM/yyyy"
    assert body["user"]["time_format"] == "HH:mm"
    assert is_binary(body["server_version"])
  end

  test "returns the user's title prefix preference", %{conn: conn, user: user} do
    assert {:ok, _user} =
             Accounts.update_player_settings(user, %{"ignore_prefixes_when_sorting" => true})

    body = json_response(get(conn, ~p"/api/me"), 200)
    assert body["user"]["ignore_prefixes_when_sorting"] == true
  end

  test "prefers PAGELESS_VERSION for server version", %{conn: conn} do
    previous = System.get_env("PAGELESS_VERSION")
    System.put_env("PAGELESS_VERSION", "20260708230000-abcdef123")

    on_exit(fn ->
      if previous do
        System.put_env("PAGELESS_VERSION", previous)
      else
        System.delete_env("PAGELESS_VERSION")
      end
    end)

    body = json_response(get(conn, ~p"/api/me"), 200)
    assert body["server_version"] == "20260708230000-abcdef123"
  end

  test "requires authentication" do
    conn = build_conn() |> put_req_header("accept", "application/json")
    assert json_response(get(conn, ~p"/api/me"), 401)
  end
end
