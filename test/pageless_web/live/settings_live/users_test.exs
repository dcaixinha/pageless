defmodule PagelessWeb.SettingsLive.UsersTest do
  use PagelessWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Pageless.AccountsFixtures

  alias Pageless.Accounts

  describe "access control" do
    test "redirects non-admin users", %{conn: conn} do
      user = user_fixture()

      assert {:error, {:redirect, %{to: "/"}}} =
               conn |> log_in_user(user) |> live(~p"/settings/users")
    end

    test "redirects anonymous users", %{conn: conn} do
      user_fixture()

      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/settings/users")
    end
  end

  describe "as admin" do
    setup %{conn: conn} do
      admin = admin_user_fixture()
      %{conn: log_in_user(conn, admin), admin: admin}
    end

    test "renders the page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings/users")
      assert html =~ "Users"
      assert html =~ "Add user"
      refute html =~ "id=\"user-modal\""
    end

    test "uses the viewer's date and time preferences", %{conn: conn, admin: admin} do
      {:ok, _admin} =
        Accounts.update_player_settings(admin, %{
          "date_format" => "MMMM do, yyyy",
          "time_format" => "h:mma"
        })

      user = user_fixture()

      user
      |> Ecto.Changeset.change(
        last_seen_at: ~U[2024-01-02 15:04:00Z],
        inserted_at: ~U[2023-03-04 05:06:00Z]
      )
      |> Pageless.Repo.update!()

      {:ok, _lv, html} = live(conn, ~p"/settings/users")

      assert html =~ "Last seen: January 2nd, 2024 3:04PM"
      assert html =~ "Created: March 4th, 2023 5:06AM"
    end

    test "creates a user", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/users")
      email = unique_user_email()

      lv |> element("#add-user-button") |> render_click()
      assert render(lv) =~ ~s(phx-window-keydown="cancel")

      lv
      |> form("#user-form",
        user: %{
          email: email,
          first_name: "Rita",
          last_name: "Reader",
          password: valid_user_password(),
          role: "user",
          enabled: "true",
          permissions: %{can_download: "true", can_access_all_libraries: "true"}
        }
      )
      |> render_submit()

      assert has_element?(lv, "#users-list", "Rita Reader")
      assert Accounts.get_user_by_email_and_password(email, valid_user_password())
    end
  end
end
