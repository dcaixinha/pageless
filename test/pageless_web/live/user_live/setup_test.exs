defmodule PagelessWeb.UserLive.SetupTest do
  use PagelessWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Pageless.AccountsFixtures

  alias Pageless.Accounts

  describe "setup page" do
    test "renders when no users exist", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/setup")

      assert html =~ "Set up Pageless"
      assert html =~ "Create admin account"
    end

    test "creates the first admin", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/setup")

      email = unique_user_email()

      {:ok, _lv, html} =
        lv
        |> form("#setup-form",
          user: %{
            first_name: "Ada",
            last_name: "Admin",
            email: email,
            password: valid_user_password()
          }
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "Admin account created"
      user = Accounts.get_user_by_email(email)
      assert user.first_name == "Ada"
      assert user.last_name == "Admin"
      assert user.role == "admin"
      assert user.enabled
      assert Accounts.get_user_by_email_and_password(email, valid_user_password())
    end

    test "redirects once setup is complete", %{conn: conn} do
      user_fixture()

      assert {:error, {:live_redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/setup")
    end
  end
end
