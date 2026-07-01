defmodule PagelessWeb.UserLive.LoginTest do
  use PagelessWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Pageless.AccountsFixtures

  describe "login page" do
    test "redirects to setup when no users exist", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/setup"}}} = live(conn, ~p"/users/log-in")
    end

    test "renders login page", %{conn: conn} do
      user_fixture()

      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Log in"
      assert html =~ "Ask an admin"
      assert html =~ "Log in and stay logged in"
      refute html =~ "Log in with email"
      refute html =~ "local mail adapter"
    end
  end

  describe "user login - password" do
    test "redirects if user logs in with valid credentials", %{conn: conn} do
      user = user_fixture() |> set_password()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password",
          user: %{email: user.email, password: valid_user_password(), remember_me: true}
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/"
    end

    test "redirects to login page with a flash error if credentials are invalid", %{
      conn: conn
    } do
      user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password", user: %{email: "test@email.com", password: "123456"})

      render_submit(form, %{user: %{remember_me: true}})

      conn = follow_trigger_action(form, conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows login page with email filled in", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "You need to reauthenticate"
      refute html =~ "Sign up"
      refute html =~ "Log in with email"

      assert html =~
               ~s(<input type="email" name="user[email]" id="login_form_password_email" value="#{user.email}")
    end
  end
end
