defmodule PagelessWeb.SettingsLive.LibrariesTest do
  use PagelessWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Pageless.AccountsFixtures

  alias Pageless.Library

  describe "access control" do
    test "redirects non-admin users", %{conn: conn} do
      user = user_fixture()

      assert {:error, {:redirect, %{to: "/"}}} =
               conn |> log_in_user(user) |> live(~p"/settings/libraries")
    end

    test "redirects anonymous users", %{conn: conn} do
      user_fixture()

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(conn, ~p"/settings/libraries")
    end
  end

  describe "as admin" do
    setup %{conn: conn} do
      admin = admin_user_fixture()
      %{conn: log_in_user(conn, admin)}
    end

    test "renders the page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings/libraries")
      assert html =~ "Manage Libraries"
      assert html =~ "Add library"
      refute html =~ "id=\"library-modal\""
    end

    test "creates a library and starts scanning", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/libraries")

      lv |> element("#add-library-button") |> render_click()
      assert render(lv) =~ ~s(phx-window-keydown="cancel")
      assert has_element?(lv, "#library_store_covers_with_item[checked]")
      assert has_element?(lv, "#library_store_metadata_with_item[checked]")
      assert has_element?(lv, "#library_auto_scan_on_file_changes[checked]")

      result =
        lv
        |> form("#library-form",
          library: %{name: "My Books", folders: %{"0" => %{path: "/data"}}}
        )
        |> render_submit()

      assert result =~ "Library created. Scan started."
      assert has_element?(lv, "li", "My Books")
      assert [%{name: "My Books"}] = Library.list_libraries()
      refute has_element?(lv, "#library-modal")
    end

    test "edits a library and its folders and storage settings", %{conn: conn} do
      {:ok, library} =
        Library.create_library(%{
          name: "Original",
          media_type: "book",
          folders: [%{path: "/original"}]
        })

      {:ok, lv, _html} = live(conn, ~p"/settings/libraries")

      lv |> element("#edit-library-#{library.id}") |> render_click()

      assert has_element?(lv, "#library-modal", "Edit library")
      assert has_element?(lv, "#library-form")

      result =
        lv
        |> form("#library-form",
          library: %{
            name: "Updated",
            folders: %{"0" => %{path: "/updated"}},
            store_covers_with_item: false,
            store_metadata_with_item: false,
            auto_scan_on_file_changes: false
          }
        )
        |> render_submit()

      assert result =~ "Library updated."
      assert has_element?(lv, "#library-#{library.id}", "Updated")
      refute has_element?(lv, "#library-modal")

      updated = Library.get_library!(library.id)
      assert updated.name == "Updated"
      assert Enum.map(updated.folders, & &1.path) == ["/updated"]
      refute updated.store_covers_with_item
      refute updated.store_metadata_with_item
      refute updated.auto_scan_on_file_changes
    end

    test "a running scan shows progress in the UI", %{conn: conn} do
      {:ok, library} = Library.create_library(%{name: "Empty", media_type: "book"})
      {:ok, lv, _html} = live(conn, ~p"/settings/libraries")

      send(lv.pid, {:scan_started, %{library_id: library.id}})

      send(
        lv.pid,
        {:scan_progress, %{library_id: library.id, current: 1, total: 4, path: "/x"}}
      )

      assert render(lv) =~ "Scanning"
    end

    test "scan_finished message updates the UI", %{conn: conn} do
      {:ok, library} = Library.create_library(%{name: "Fixtures", media_type: "book"})
      {:ok, lv, _html} = live(conn, ~p"/settings/libraries")

      # Simulate the scan lifecycle messages the running task would broadcast.
      send(lv.pid, {:scan_started, %{library_id: library.id}})

      send(
        lv.pid,
        {:scan_finished,
         %{library_id: library.id, result: %{scanned: 3, errors: 0, missing: 0, total: 3}}}
      )

      assert render(lv) =~ "Imported 3 books"
    end

    test "scan failure re-enables the library controls", %{conn: conn} do
      {:ok, library} = Library.create_library(%{name: "Broken", media_type: "book"})
      {:ok, lv, _html} = live(conn, ~p"/settings/libraries")

      send(lv.pid, {:scan_started, %{library_id: library.id}})
      send(lv.pid, {:scan_failed, %{library_id: library.id, reason: :boom}})

      assert render(lv) =~ "Library scan failed"
      refute has_element?(lv, "#scan-library-#{library.id}[disabled]")
    end
  end
end
