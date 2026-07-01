defmodule PagelessWeb.PlayerLiveTest do
  use PagelessWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Pageless.AccountsFixtures
  import Pageless.LibraryFixtures

  alias PagelessWeb.PlayerLive
  alias Pageless.Playback.ListeningSession

  setup %{conn: conn} do
    user = user_fixture()
    book = book_fixture(%{title: "Playable", duration_seconds: 100.0})
    %{conn: log_in_user(conn, user), user: user, book: book}
  end

  test "shows nothing playing initially", %{conn: conn} do
    {:ok, _lv, html} = live_isolated(conn, PlayerLive)
    assert html =~ "Nothing playing"
  end

  test "play broadcast loads the book and pushes a play event", %{
    conn: conn,
    user: user,
    book: book
  } do
    {:ok, lv, _html} = live_isolated(conn, PlayerLive)

    PlayerLive.play(user.id, book.id)

    assert render(lv) =~ "Playable"
    assert_push_event(lv, "play", %{title: "Playable"})
  end

  test "the book title links to the book page", %{conn: conn, user: user, book: book} do
    {:ok, lv, _html} = live_isolated(conn, PlayerLive)
    PlayerLive.play(user.id, book.id)
    render(lv)

    assert has_element?(lv, ~s|#player a[href="/books/#{book.id}"]|, "Playable")
  end

  test "toggling pause/resume pushes events", %{conn: conn, user: user, book: book} do
    {:ok, lv, _html} = live_isolated(conn, PlayerLive)
    PlayerLive.play(user.id, book.id)
    render(lv)

    render_click(element(lv, "#player button[phx-click=toggle]"))
    assert_push_event(lv, "pause", %{})
  end

  test "progress events persist playback position", %{conn: conn, user: user, book: book} do
    {:ok, lv, _html} = live_isolated(conn, PlayerLive)
    PlayerLive.play(user.id, book.id)
    render(lv)

    render_hook(element(lv, "#player"), "progress", %{"position" => 42.0, "duration" => 100.0})

    scope = user_scope_fixture(user)
    assert Pageless.Playback.resume_position(scope, book.id) == 42.0
  end

  test "preview playback does not persist progress", %{conn: conn, user: user, book: book} do
    {:ok, lv, _html} = live_isolated(conn, PlayerLive)
    PlayerLive.play(user.id, book.id, 10.0, preview: true)
    render(lv)

    render_hook(element(lv, "#player"), "progress", %{"position" => 42.0, "duration" => 100.0})

    scope = user_scope_fixture(user)
    assert Pageless.Playback.resume_position(scope, book.id) == 0.0
  end

  test "normal playback starts a listening session", %{conn: conn, user: user, book: book} do
    {:ok, lv, _html} = live_isolated(conn, PlayerLive)
    PlayerLive.play(user.id, book.id)
    render(lv)

    render_hook(element(lv, "#player"), "playing", %{"playing" => true})

    assert [session] = Pageless.Repo.all(ListeningSession)
    assert session.user_id == user.id
    assert session.book_id == book.id
    assert session.play_method == "Direct Play"
    assert session.device_info =~ "Pageless Web"
  end

  test "preview playback does not start a listening session", %{
    conn: conn,
    user: user,
    book: book
  } do
    {:ok, lv, _html} = live_isolated(conn, PlayerLive)
    PlayerLive.play(user.id, book.id, 10.0, preview: true)
    render(lv)

    render_hook(element(lv, "#player"), "playing", %{"playing" => true})

    assert Pageless.Repo.all(ListeningSession) == []
  end

  test "a normal play after preview resumes persisting", %{conn: conn, user: user, book: book} do
    {:ok, lv, _html} = live_isolated(conn, PlayerLive)

    PlayerLive.play(user.id, book.id, 10.0, preview: true)
    render(lv)
    PlayerLive.play(user.id, book.id)
    render(lv)

    render_hook(element(lv, "#player"), "progress", %{"position" => 55.0, "duration" => 100.0})

    scope = user_scope_fixture(user)
    assert Pageless.Playback.resume_position(scope, book.id) == 55.0
  end

  test "play event includes chapters", %{conn: conn, user: user, book: book} do
    chapter_fixture(book, %{title: "One", start_seconds: 0.0, end_seconds: 50.0, index: 0})
    chapter_fixture(book, %{title: "Two", start_seconds: 50.0, end_seconds: 100.0, index: 1})

    {:ok, lv, _html} = live_isolated(conn, PlayerLive)
    PlayerLive.play(user.id, book.id)

    assert_push_event(lv, "play", %{chapters: chapters, duration: 100.0})
    assert [%{title: "One", start: first_start}, %{title: "Two", start: 50.0}] = chapters
    assert first_start == 0.0
  end

  describe "chapter navigation" do
    setup %{book: book} do
      chapter_fixture(book, %{title: "One", start_seconds: 0.0, end_seconds: 50.0, index: 0})
      chapter_fixture(book, %{title: "Two", start_seconds: 50.0, end_seconds: 100.0, index: 1})
      :ok
    end

    test "next_chapter seeks to the next chapter start", %{conn: conn, user: user, book: book} do
      {:ok, lv, _html} = live_isolated(conn, PlayerLive)
      PlayerLive.play(user.id, book.id)
      render(lv)

      # We're at position 0 (chapter One) -> next jumps to 50 (chapter Two).
      render_click(element(lv, "#player button[phx-click=next_chapter]"))
      assert_push_event(lv, "seek", %{position: 50.0})
    end

    test "prev_chapter restarts the current chapter when a few seconds in", %{
      conn: conn,
      user: user,
      book: book
    } do
      {:ok, lv, _html} = live_isolated(conn, PlayerLive)
      PlayerLive.play(user.id, book.id)
      render(lv)

      # Move into chapter Two, then prev should restart it (position 50).
      render_hook(element(lv, "#player"), "progress", %{"position" => 70.0, "duration" => 100.0})
      render_click(element(lv, "#player button[phx-click=prev_chapter]"))
      assert_push_event(lv, "seek", %{position: 50.0})
    end

    test "nudge pushes a delta to the hook", %{conn: conn, user: user, book: book} do
      {:ok, lv, _html} = live_isolated(conn, PlayerLive)
      PlayerLive.play(user.id, book.id)
      render(lv)

      render_click(element(lv, "#player button[phx-click=nudge][phx-value-delta='30']"))
      assert_push_event(lv, "nudge", %{delta: 30.0})
    end
  end

  describe "player settings" do
    test "opening and closing the settings modal", %{conn: conn, user: user, book: book} do
      {:ok, lv, _html} = live_isolated(conn, PlayerLive)
      PlayerLive.play(user.id, book.id)
      render(lv)

      refute has_element?(lv, "#player-settings-modal")
      render_click(element(lv, "#player button[phx-click=open_settings]"))
      assert has_element?(lv, "#player-settings-modal")

      render_click(element(lv, "#player-settings-modal button[phx-click=close_settings]"))
      refute has_element?(lv, "#player-settings-modal")
    end

    test "saving settings persists and pushes to the hook", %{conn: conn, user: user, book: book} do
      {:ok, lv, _html} = live_isolated(conn, PlayerLive)
      PlayerLive.play(user.id, book.id)
      render(lv)
      render_click(element(lv, "#player button[phx-click=open_settings]"))

      lv
      |> form("#player-settings-form", %{
        settings: %{
          use_chapter_track: "false",
          jump_forward: "10",
          jump_backward: "5",
          rate_increment: "0.25"
        }
      })
      |> render_change()

      assert_push_event(lv, "settings", %{use_chapter_track: false})

      settings =
        Pageless.Accounts.get_player_settings(Pageless.Accounts.get_user_by_email(user.email))

      assert settings.jump_forward == 10
      assert settings.use_chapter_track == false
    end

    test "use_chapter_track is sent in the play event", %{conn: conn, user: user, book: book} do
      Pageless.Accounts.update_player_settings(user, %{"use_chapter_track" => "false"})

      {:ok, lv, _html} = live_isolated(conn, PlayerLive)
      PlayerLive.play(user.id, book.id)

      assert_push_event(lv, "play", %{use_chapter_track: false})
    end

    test "step_speed adjusts speed by the configured increment", %{
      conn: conn,
      user: user,
      book: book
    } do
      Pageless.Accounts.update_player_settings(user, %{"rate_increment" => "0.25"})

      {:ok, lv, _html} = live_isolated(conn, PlayerLive)
      PlayerLive.play(user.id, book.id)
      render(lv)

      render_click(element(lv, "#player button[phx-click=step_speed][phx-value-dir='1']"))
      assert_push_event(lv, "set_speed", %{speed: 1.25})
    end

    test "changing speed persists the playback rate", %{conn: conn, user: user, book: book} do
      {:ok, lv, _html} = live_isolated(conn, PlayerLive)
      PlayerLive.play(user.id, book.id)
      render(lv)

      render_click(element(lv, "#player button[phx-click=step_speed][phx-value-dir='1']"))

      settings =
        Pageless.Accounts.get_player_settings(Pageless.Accounts.get_user_by_email(user.email))

      assert settings.playback_rate == 1.1
    end

    test "saved playback rate is restored and sent on play", %{conn: conn, user: user, book: book} do
      Pageless.Accounts.update_player_settings(user, %{"playback_rate" => "1.5"})

      {:ok, lv, _html} = live_isolated(conn, PlayerLive)
      PlayerLive.play(user.id, book.id)

      assert_push_event(lv, "play", %{speed: 1.5})
    end
  end

  describe "chapters modal" do
    setup %{book: book} do
      chapter_fixture(book, %{title: "Intro", start_seconds: 0.0, end_seconds: 50.0, index: 0})
      chapter_fixture(book, %{title: "Middle", start_seconds: 50.0, end_seconds: 90.0, index: 1})
      :ok
    end

    test "opening and closing the chapters modal", %{conn: conn, user: user, book: book} do
      {:ok, lv, _html} = live_isolated(conn, PlayerLive)
      PlayerLive.play(user.id, book.id)
      render(lv)

      refute has_element?(lv, "#player-chapters-modal")
      render_click(element(lv, "#player button[phx-click=open_chapters]"))

      assert has_element?(lv, "#player-chapters-modal", "Intro")
      assert has_element?(lv, "#player-chapters-modal", "Middle")

      render_click(element(lv, "#player-chapters-modal button[phx-click=close_chapters]"))
      refute has_element?(lv, "#player-chapters-modal")
    end

    test "clicking a chapter seeks and closes the modal", %{conn: conn, user: user, book: book} do
      {:ok, lv, _html} = live_isolated(conn, PlayerLive)
      PlayerLive.play(user.id, book.id)
      render(lv)
      render_click(element(lv, "#player button[phx-click=open_chapters]"))

      lv
      |> element("#player-chapters-modal button[phx-value-start='50.0']")
      |> render_click()

      assert_push_event(lv, "seek", %{position: 50.0})
      refute has_element?(lv, "#player-chapters-modal")
    end

    test "the current chapter is highlighted", %{conn: conn, user: user, book: book} do
      {:ok, lv, _html} = live_isolated(conn, PlayerLive)
      PlayerLive.play(user.id, book.id)
      render(lv)

      # Move playback into the second chapter.
      render_hook(element(lv, "#player"), "progress", %{"position" => 70.0, "duration" => 90.0})
      render_click(element(lv, "#player button[phx-click=open_chapters]"))

      assert has_element?(
               lv,
               "#player-chapters-modal button.border-primary[phx-value-start='50.0']"
             )
    end

    test "no chapters button when the book has no chapters", %{conn: conn, user: user} do
      no_chapters = book_fixture(%{title: "Plain", duration_seconds: 100.0})

      {:ok, lv, _html} = live_isolated(conn, PlayerLive)
      PlayerLive.play(user.id, no_chapters.id)
      render(lv)

      refute has_element?(lv, "#player button[phx-click=open_chapters]")
    end
  end

  describe "bookmarks" do
    test "add a bookmark at the current position with a note", %{
      conn: conn,
      user: user,
      book: book
    } do
      {:ok, lv, _html} = live_isolated(conn, PlayerLive)
      PlayerLive.play(user.id, book.id)
      render(lv)

      # Advance playback so the bookmark is created at a known position.
      render_hook(element(lv, "#player"), "progress", %{"position" => 42.0, "duration" => 100.0})

      render_click(element(lv, "#player button[phx-click=open_bookmarks]"))
      assert has_element?(lv, "#player-bookmarks-modal", "No bookmarks yet")

      lv
      |> form("#player-bookmarks-modal form", %{note: "Great point"})
      |> render_submit()

      assert has_element?(lv, "#player-bookmarks-modal", "Great point")
      assert has_element?(lv, "#player-bookmarks-modal", "0:42")
    end

    test "clicking a bookmark seeks and closes the modal", %{conn: conn, user: user, book: book} do
      scope = Pageless.Accounts.Scope.for_user(user)
      {:ok, _} = Pageless.Playback.create_bookmark(scope, book.id, 55.0, "note")

      {:ok, lv, _html} = live_isolated(conn, PlayerLive)
      PlayerLive.play(user.id, book.id)
      render(lv)

      render_click(element(lv, "#player button[phx-click=open_bookmarks]"))
      lv |> element("#player-bookmarks-modal button[phx-value-position='55.0']") |> render_click()

      assert_push_event(lv, "seek", %{position: 55.0})
      refute has_element?(lv, "#player-bookmarks-modal")
    end

    test "deleting a bookmark removes it from the list", %{conn: conn, user: user, book: book} do
      scope = Pageless.Accounts.Scope.for_user(user)
      {:ok, bookmark} = Pageless.Playback.create_bookmark(scope, book.id, 12.0, "temp")

      {:ok, lv, _html} = live_isolated(conn, PlayerLive)
      PlayerLive.play(user.id, book.id)
      render(lv)

      render_click(element(lv, "#player button[phx-click=open_bookmarks]"))
      assert has_element?(lv, "#player-bookmarks-modal", "temp")

      lv
      |> element("#player-bookmarks-modal button[phx-value-id='#{bookmark.id}']")
      |> render_click()

      refute has_element?(lv, "#player-bookmarks-modal", "temp")
    end
  end
end
