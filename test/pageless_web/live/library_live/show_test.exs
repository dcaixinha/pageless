defmodule PagelessWeb.LibraryLive.ShowTest do
  use PagelessWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, except: [live: 2]
  import Pageless.AccountsFixtures
  import Pageless.LibraryFixtures

  alias Pageless.Accounts
  alias Pageless.Library
  alias Pageless.Playback

  setup %{conn: conn} do
    user = admin_user_fixture()
    book = book_fixture(%{title: "The Hobbit", duration_seconds: 1000.0})
    chapter_fixture(book, %{title: "An Unexpected Party", start_seconds: 0.0, end_seconds: 500.0})

    %{conn: log_in_user(conn, user), book: book, scope: user_scope_fixture(user)}
  end

  test "renders book metadata and chapters", %{conn: conn, book: book} do
    {:ok, lv, html} = live(conn, ~p"/books/#{book.id}")
    assert has_element?(lv, "a[href='/library']", "Back to library")
    assert html =~ "The Hobbit"
    assert html =~ "An Unexpected Party"
    assert html =~ "Chapters (1)"
    assert html =~ "Title"
    assert html =~ "Start"
    assert html =~ "Duration"
    assert html =~ "8m 20s"
    assert has_element?(lv, "#book-cover-frame[class~='md:w-64']")
    assert has_element?(lv, "#book-hero-details.flex.flex-col")
    assert has_element?(lv, "#book-hero-actions[class~='md:mt-auto']")
  end

  test "refreshes changed book details after a scan", %{conn: conn, book: book} do
    {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
    {:ok, _book} = Library.update_book(book, %{"title" => "The Hobbit Revised"})

    Pageless.Library.Events.broadcast_changed(book.library_id, [book.id], [])

    assert has_element?(lv, "h1", "The Hobbit Revised")
  end

  test "navigates to the library when a scan removes the current book", %{
    conn: conn,
    book: book
  } do
    {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
    {:ok, _book} = Library.delete_book(book)

    Pageless.Library.Events.broadcast_changed(book.library_id, [], [book.id])

    assert_redirect(lv, ~p"/library")
  end

  test "links filterable metadata to the filtered library", %{conn: conn, book: book} do
    author = Library.upsert_author("J.R.R. Tolkien")
    genre = Library.upsert_genre("Fantasy")
    series = Library.upsert_series("Middle-earth")
    narrator = Library.upsert_narrator("Andy Serkis")
    publisher = Library.upsert_publisher("HarperCollins")

    {:ok, _book} =
      Library.update_book(book, %{
        "authors" => author.name,
        "genres" => genre.name,
        "publisher" => publisher.name,
        "language" => "English"
      })

    Library.set_book_series(book, [%{name: series.name, sequence: "1"}])
    {:ok, :ok} = Library.replace_book_narrators(book, [narrator.name])

    {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")

    assert has_element?(
             lv,
             "#book-author-link-#{author.id}[href='#{~p"/library?#{%{"authors" => [author.id]}}"}']"
           )

    assert has_element?(
             lv,
             "#book-genre-link-#{genre.id}[href='#{~p"/library?#{%{"genres" => [genre.id]}}"}']"
           )

    assert has_element?(
             lv,
             "#book-series-link-#{series.id}[href='#{~p"/library?#{%{"series" => [series.id]}}"}']"
           )

    assert has_element?(
             lv,
             "#book-narrator-link-#{narrator.id}[href='#{~p"/library?#{%{"narrators" => [narrator.id]}}"}']"
           )

    assert has_element?(
             lv,
             "#book-publisher-link-#{publisher.id}[href='#{~p"/library?#{%{"publishers" => [publisher.id]}}"}']"
           )

    assert has_element?(
             lv,
             "#book-language-link[href='#{~p"/library?#{%{"languages" => ["English"]}}"}']"
           )
  end

  test "shows Play when there is no progress", %{conn: conn, book: book} do
    {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
    assert has_element?(lv, "button", "Play")
    refute has_element?(lv, "button", "Resume")
  end

  test "shows Resume when there is saved progress", %{conn: conn, book: book, scope: scope} do
    Playback.save_progress(scope, book.id, 300.0, 1000.0)

    {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
    assert has_element?(lv, "button", "Resume")
  end

  test "clicking play broadcasts to the player", %{conn: conn, book: book, scope: scope} do
    Phoenix.PubSub.subscribe(Pageless.PubSub, PagelessWeb.PlayerLive.topic(scope.user.id))

    {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
    lv |> element("button", "Play") |> render_click()

    assert_receive {:play_book, book_id, nil, false}
    assert book_id == book.id
    render_player(lv)
  end

  test "clicking a chapter broadcasts a seek position", %{conn: conn, book: book, scope: scope} do
    Phoenix.PubSub.subscribe(Pageless.PubSub, PagelessWeb.PlayerLive.topic(scope.user.id))

    {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
    lv |> element("button[phx-click=play_chapter]") |> render_click()

    assert_receive {:play_book, _book_id, start, false}
    assert start == 0.0
    render_player(lv)
  end

  test "renders bookmarks above chapters", %{conn: conn, book: book, scope: scope} do
    {:ok, _bookmark} = Playback.create_bookmark(scope, book.id, 42.0, "Great point")

    {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")

    assert has_element?(lv, "h2", "Bookmarks (1)")
    assert has_element?(lv, "#bookmark-group-0", "An Unexpected Party")
    assert has_element?(lv, "#bookmark-group-0", "Great point")
    assert has_element?(lv, "#bookmark-group-0", "0:42")
  end

  test "bookmark section can be collapsed", %{conn: conn, book: book, scope: scope} do
    {:ok, _bookmark} = Playback.create_bookmark(scope, book.id, 42.0, "Great point")
    {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")

    assert has_element?(lv, "#bookmark-group-0", "Great point")
    lv |> element("button[phx-click=toggle_bookmarks]") |> render_click()
    refute has_element?(lv, "#bookmark-group-0", "Great point")
    assert has_element?(lv, "h2", "Bookmarks (1)")
  end

  test "chapters section can be collapsed", %{conn: conn, book: book} do
    {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")

    assert has_element?(lv, "button[phx-click=play_chapter]", "An Unexpected Party")
    lv |> element("button[phx-click=toggle_chapters]") |> render_click()
    refute has_element?(lv, "button[phx-click=play_chapter]", "An Unexpected Party")
    assert has_element?(lv, "h2", "Chapters (1)")
  end

  test "clicking a bookmark opens a preview player modal", %{conn: conn, book: book, scope: scope} do
    Phoenix.PubSub.subscribe(Pageless.PubSub, PagelessWeb.PlayerLive.topic(scope.user.id))
    {:ok, bookmark} = Playback.create_bookmark(scope, book.id, 42.0, "Great point")

    {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
    html = lv |> element("#bookmark-#{bookmark.id}") |> render_click()

    assert html =~ "bookmark-preview-modal"
    assert html =~ "Bookmark at 0:42"
    assert html =~ "An Unexpected Party"
    assert html =~ "Great point"
    assert html =~ "/books/#{book.id}/audio?token="
    assert html =~ "data-start=\"42.0\""
    assert html =~ "data-preview-action=\"back\""
    assert html =~ "data-preview-action=\"forward\""
    assert html =~ "Play from here"
    refute html =~ "Preview playback does not update your saved book progress."
    refute html =~ "autoplay"
    refute_receive {:play_book, _book_id, _start, _preview?}
  end

  test "play from bookmark preview starts normal playback", %{
    conn: conn,
    book: book,
    scope: scope
  } do
    Phoenix.PubSub.subscribe(Pageless.PubSub, PagelessWeb.PlayerLive.topic(scope.user.id))
    {:ok, bookmark} = Playback.create_bookmark(scope, book.id, 42.0, "Great point")

    {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
    lv |> element("#bookmark-#{bookmark.id}") |> render_click()
    lv |> element("#bookmark-preview-modal button", "Play from here") |> render_click()

    book_id = book.id
    assert_receive {:play_book, ^book_id, 42.0, false}
    refute has_element?(lv, "#bookmark-preview-modal")
    render_player(lv)
  end

  test "shows Pause when this book is playing", %{
    conn: conn,
    book: book,
    scope: scope
  } do
    Phoenix.PubSub.subscribe(Pageless.PubSub, PagelessWeb.PlayerLive.topic(scope.user.id))
    {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")

    send(lv.pid, {:player_state, %{book_id: book.id, playing: true}})

    assert has_element?(lv, "button", "Pause")
    refute has_element?(lv, "button", "Resume")

    lv |> element("button", "Pause") |> render_click()
    assert_receive :toggle_playback
  end

  test "does not show Pause when a different book is playing", %{conn: conn, book: book} do
    {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")

    send(lv.pid, {:player_state, %{book_id: Ecto.UUID.generate(), playing: true}})

    refute has_element?(lv, "button", "Pause")
    assert has_element?(lv, "button", "Play")
  end

  test "shows Play when this book is loaded but paused", %{conn: conn, book: book, scope: scope} do
    Phoenix.PubSub.subscribe(Pageless.PubSub, PagelessWeb.PlayerLive.topic(scope.user.id))
    Playback.save_progress(scope, book.id, 300.0, 1000.0)
    {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")

    send(lv.pid, {:player_state, %{book_id: book.id, playing: true}})
    assert has_element?(lv, "button", "Pause")

    send(lv.pid, {:player_state, %{book_id: book.id, playing: false}})
    refute has_element?(lv, "button", "Pause")
    assert has_element?(lv, "button", "Play")

    lv |> element("button", "Play") |> render_click()
    assert_receive :toggle_playback
  end

  test "remove progress deletes the record and hides the panel", %{
    conn: conn,
    book: book,
    scope: scope
  } do
    Playback.save_progress(scope, book.id, 300.0, 1000.0)
    {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")

    assert has_element?(lv, "button[phx-click=remove_progress]")
    lv |> element("button[phx-click=remove_progress]") |> render_click()

    refute has_element?(lv, "button[phx-click=remove_progress]")
    refute Playback.get_progress(scope, book.id)
  end

  test "highlights the current chapter based on player position", %{conn: conn, book: book} do
    chapter_fixture(book, %{
      title: "Second Chapter",
      start_seconds: 500.0,
      end_seconds: 1000.0,
      index: 1
    })

    {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")

    # Position inside the second chapter -> that row is highlighted.
    send(lv.pid, {:player_state, %{book_id: book.id, playing: true, position: 700.0}})

    assert has_element?(lv, ~s(li[class*="bg-primary/15"]), "Second Chapter")
    refute has_element?(lv, ~s(li[class*="bg-primary/15"]), "An Unexpected Party")
  end

  test "highlights the current chapter based on saved progress", %{
    conn: conn,
    book: book,
    scope: scope
  } do
    chapter_fixture(book, %{
      title: "Second Chapter",
      start_seconds: 500.0,
      end_seconds: 1000.0,
      index: 1
    })

    Playback.save_progress(scope, book.id, 700.0, 1000.0)

    {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")

    assert has_element?(lv, ~s(li[class*="bg-primary/15"]), "Second Chapter")
    refute has_element?(lv, ~s(li[class*="bg-primary/15"]), "An Unexpected Party")
  end

  test "keeps saved chapter during startup zero position and updates summary from player state",
       %{
         conn: conn,
         book: book,
         scope: scope
       } do
    chapter_fixture(book, %{
      title: "Second Chapter",
      start_seconds: 500.0,
      end_seconds: 1000.0,
      index: 1
    })

    Playback.save_progress(scope, book.id, 700.0, 1000.0)
    {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")

    send(lv.pid, {:player_state, %{book_id: book.id, playing: true, position: 0.0}})
    html = render(lv)
    assert html =~ "Your Progress: 70%"
    assert html =~ "5m remaining"
    assert html =~ "Current chapter: Second Chapter"
    assert has_element?(lv, ~s(li[class*="bg-primary/15"]), "Second Chapter")

    send(lv.pid, {:player_state, %{book_id: book.id, playing: true, position: 800.0}})
    html = render(lv)
    assert html =~ "Your Progress: 80%"
    assert html =~ "3m remaining"
    assert html =~ "Current chapter: Second Chapter"
  end

  test "does not highlight chapters when a different book plays", %{conn: conn, book: book} do
    {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")

    send(
      lv.pid,
      {:player_state, %{book_id: Ecto.UUID.generate(), playing: true, position: 100.0}}
    )

    refute has_element?(lv, ~s(li[class*="bg-primary/15"]))
  end

  describe "description" do
    test "renders formatting tags as HTML, not escaped text", %{conn: conn} do
      book =
        book_fixture(%{
          title: "Formatted",
          description: "<p>The <i>Sunday Times</i> best seller.</p>"
        })

      {:ok, _lv, html} = live(conn, ~p"/books/#{book.id}")
      assert html =~ "<i>Sunday Times</i>"
      refute html =~ "&lt;i&gt;Sunday Times"
    end

    test "shows Read more for long descriptions and toggles", %{conn: conn} do
      long = "<p>" <> String.duplicate("word ", 100) <> "</p>"
      book = book_fixture(%{title: "Long", description: long})

      {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
      assert has_element?(lv, "button[phx-click=toggle_description]", "Read more")

      html = lv |> element("button[phx-click=toggle_description]") |> render_click()
      assert html =~ "Read less"
    end

    test "no Read more button for short descriptions", %{conn: conn} do
      book = book_fixture(%{title: "Short", description: "<p>Tiny.</p>"})

      {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
      refute has_element?(lv, "button[phx-click=toggle_description]")
    end
  end

  describe "finished state" do
    test "uses the viewer's date preference for progress dates", %{
      conn: conn,
      book: book,
      scope: scope
    } do
      {:ok, _user} =
        Accounts.update_player_settings(scope.user, %{"date_format" => "MMMM do, yyyy"})

      progress = Playback.save_progress(scope, book.id, 100.0, 1000.0)

      progress
      |> Ecto.Changeset.change(
        started_at: ~U[2024-01-02 03:04:05Z],
        finished_at: ~U[2024-03-04 05:06:07Z]
      )
      |> Pageless.Repo.update!()

      {:ok, _lv, html} = live(conn, ~p"/books/#{book.id}")

      assert html =~ "Finished"
      assert html =~ "March 4th, 2024"
      assert html =~ "Started January 2nd, 2024"
    end

    test "shows Mark as finished by default", %{conn: conn, book: book} do
      {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
      assert has_element?(lv, "button[phx-click=mark_finished]", "Mark as finished")
      refute has_element?(lv, "button[phx-click=mark_not_finished]")
    end

    test "marking finished updates the button and shows Finished", %{conn: conn, book: book} do
      {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")

      lv |> element("button[phx-click=mark_finished]") |> render_click()

      assert has_element?(lv, "button[phx-click=mark_not_finished]", "Mark as not finished")
      assert render(lv) =~ "Finished"
    end

    test "marking not finished reverts", %{conn: conn, book: book, scope: scope} do
      Playback.mark_finished(scope, book.id, book.duration_seconds)
      {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
      assert has_element?(lv, "button[phx-click=mark_not_finished]")

      lv |> element("button[phx-click=mark_not_finished]") |> render_click()
      assert has_element?(lv, "button[phx-click=mark_finished]")
    end

    test "shows progress summary", %{conn: conn, book: book, scope: scope} do
      Playback.save_progress(scope, book.id, 100.0, 1000.0)

      {:ok, _lv, html} = live(conn, ~p"/books/#{book.id}")
      assert html =~ "Your Progress: 10%"
      assert html =~ "15m remaining"
      assert html =~ "Current chapter: An Unexpected Party"
    end

    test "finished book with no saved position fills the progress bar", %{
      conn: conn,
      book: book,
      scope: scope
    } do
      # Simulate a book imported as finished from Audiobookshelf: finished_at is
      # set but there is no listening position.
      now = DateTime.utc_now(:second)

      {1, _} =
        Pageless.Repo.insert_all(Pageless.Playback.PlaybackProgress, [
          %{
            id: Ecto.UUID.generate(),
            user_id: scope.user.id,
            book_id: book.id,
            current_seconds: 0.0,
            duration_seconds: book.duration_seconds,
            finished_at: now,
            last_played_at: now,
            inserted_at: now,
            updated_at: now
          }
        ])

      {:ok, _lv, html} = live(conn, ~p"/books/#{book.id}")

      assert html =~ "Finished"
      assert html =~ "width: 100%"
      refute html =~ "width: 0%"
      # A finished book with no position must not highlight the first chapter.
      refute html =~ "Current chapter:"
      refute html =~ "hero-speaker-wave-solid"
    end
  end

  describe "edit details" do
    test "opening and closing the edit modal", %{conn: conn, book: book} do
      {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")

      refute has_element?(lv, "#book-edit-modal")
      lv |> element("button[phx-click=open_edit]") |> render_click()
      assert has_element?(lv, "#book-edit-form")
      assert has_element?(lv, "#book-edit-dialog[class~='h-[85vh]']")

      lv |> element("#book-edit-modal button[aria-label=Close]") |> render_click()
      refute has_element?(lv, "#book-edit-modal")
    end

    test "saving updates the book details", %{conn: conn, book: book} do
      {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
      lv |> element("button[phx-click=open_edit]") |> render_click()

      form =
        form(lv, "#book-edit-form",
          book: %{
            title: "Edited Title",
            authors: "New Author",
            publisher_name: "New Publisher"
          }
        )

      render_change(form)
      assert has_element?(lv, "input[name='book[publisher_name]'][value='New Publisher']")
      render_submit(form)

      refute has_element?(lv, "#book-edit-modal")
      assert render(lv) =~ "Edited Title"
      assert render(lv) =~ "New Author"

      updated = Library.get_book!(book.id)
      assert updated.title == "Edited Title"
      assert Enum.map(updated.authors, & &1.name) == ["New Author"]
      assert updated.publisher.name == "New Publisher"
    end

    test "saving updates ordered narrators via tag inputs", %{conn: conn, book: book} do
      {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
      lv |> element("button[phx-click=open_edit]") |> render_click()

      render_hook(lv, "tag_add_narrator", %{"name" => "Doe, Jane"})
      render_hook(lv, "tag_add_narrator", %{"name" => "Second Reader"})

      lv
      |> form("#book-edit-form",
        book: %{title: book.title, pending_narrators: "Saved Without Pressing Enter"}
      )
      |> render_submit()

      assert ["Doe, Jane", "Second Reader", "Saved Without Pressing Enter"] =
               Library.get_book!(book.id).book_narrators
               |> Enum.map(& &1.narrator.name)
    end

    test "saving updates series and collections via tag inputs", %{conn: conn, book: book} do
      {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
      lv |> element("button[phx-click=open_edit]") |> render_click()

      render_hook(lv, "tag_add_series", %{"name" => "Uma Aventura #3"})
      render_hook(lv, "tag_add_collection", %{"name" => "Kids"})
      render_hook(lv, "tag_add_collection", %{"name" => "Faves"})

      lv
      |> form("#book-edit-form", book: %{title: book.title})
      |> render_submit()

      refute has_element?(lv, "#book-edit-modal")

      updated =
        Library.get_book!(book.id)
        |> Pageless.Repo.preload([
          :book_series,
          book_series: :series,
          book_collections: :collection
        ])

      assert [%{series: %{name: "Uma Aventura"}, sequence: "3"}] = updated.book_series

      collection_names =
        Enum.map(updated.book_collections, & &1.collection.name) |> Enum.sort()

      assert collection_names == ["Faves", "Kids"]
    end

    test "shows autocomplete suggestions and a create option", %{conn: conn, book: book} do
      other = book_fixture(%{library_id: book.library_id})
      Library.set_book_series(other, [%{name: "Existing Series", sequence: "1"}])

      {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")

      # On open (empty query) the suggestions dropdown must be collapsed.
      html = lv |> element("button[phx-click=open_edit]") |> render_click()
      refute html =~ "Existing Series"

      html = render_hook(lv, "tag_filter", %{"field" => "series", "value" => "Exist"})
      assert html =~ "Existing Series"

      # A valid new series (with #number) offers a create option.
      html = render_hook(lv, "tag_filter", %{"field" => "series", "value" => "Totally New #1"})
      assert html =~ "Create &quot;Totally New #1&quot;"
    end

    test "collections offer a create option for any new name", %{conn: conn, book: book} do
      {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
      lv |> element("button[phx-click=open_edit]") |> render_click()

      html = render_hook(lv, "tag_filter", %{"field" => "collections", "value" => "Brand New"})
      assert html =~ "Create &quot;Brand New&quot;"
    end

    test "rejects a new series without a #number and alerts", %{conn: conn, book: book} do
      {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
      lv |> element("button[phx-click=open_edit]") |> render_click()

      # No create option for an invalid series (missing #number).
      html = render_hook(lv, "tag_filter", %{"field" => "series", "value" => "No Number"})
      refute html =~ "Create &quot;No Number&quot;"

      # Attempting to add it surfaces an inline error and adds nothing.
      html = render_hook(lv, "tag_add_series", %{"name" => "No Number"})
      assert html =~ "must include a number"

      lv |> form("#book-edit-form", book: %{title: book.title}) |> render_submit()
      updated = Library.get_book!(book.id) |> Pageless.Repo.preload(:book_series)
      assert updated.book_series == []
    end

    test "clears the series error when typing resumes", %{conn: conn, book: book} do
      {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
      lv |> element("button[phx-click=open_edit]") |> render_click()

      html = render_hook(lv, "tag_add_series", %{"name" => "No Number"})
      assert html =~ "must include a number"

      html = render_hook(lv, "tag_filter", %{"field" => "series", "value" => "No Numb"})
      refute html =~ "must include a number"
    end

    test "selecting an existing series prefills for a sequence instead of adding",
         %{conn: conn, book: book} do
      other = book_fixture(%{library_id: book.library_id})
      Library.set_book_series(other, [%{name: "Existing Series", sequence: "1"}])

      {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
      lv |> element("button[phx-click=open_edit]") |> render_click()

      # Prefill does not add a pill and raises no error.
      html = render_hook(lv, "tag_prefill_series", %{"name" => "Existing Series"})
      refute html =~ "must include a number"

      # After typing the sequence, adding works and persists on save.
      render_hook(lv, "tag_add_series", %{"name" => "Existing Series #4"})
      lv |> form("#book-edit-form", book: %{title: book.title}) |> render_submit()

      updated =
        Library.get_book!(book.id) |> Pageless.Repo.preload(book_series: :series)

      assert [%{series: %{name: "Existing Series"}, sequence: "4"}] = updated.book_series
    end

    test "removing a series pill drops it before save", %{conn: conn, book: book} do
      Library.set_book_series(book, [%{name: "To Remove", sequence: "1"}])
      {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
      lv |> element("button[phx-click=open_edit]") |> render_click()

      render_hook(lv, "tag_remove_series", %{"name" => "To Remove"})
      lv |> form("#book-edit-form", book: %{title: book.title}) |> render_submit()

      updated = Library.get_book!(book.id) |> Pageless.Repo.preload(:book_series)
      assert updated.book_series == []
    end

    test "shows validation errors for an invalid title", %{conn: conn, book: book} do
      {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
      lv |> element("button[phx-click=open_edit]") |> render_click()

      html =
        lv
        |> form("#book-edit-form", book: %{title: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
      assert has_element?(lv, "#book-edit-modal")
    end
  end

  describe "cover tab" do
    setup %{book: book} do
      on_exit(fn -> Pageless.Media.delete_covers(book.id) end)
      :ok
    end

    test "switching to the Cover tab", %{conn: conn, book: book} do
      {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
      lv |> element("button[phx-click=open_edit]") |> render_click()

      lv |> element("button[phx-click=edit_tab][phx-value-tab=cover]") |> render_click()

      assert has_element?(lv, "#cover-upload-form")
      assert has_element?(lv, "#cover-url-form")
    end

    test "URL submit is disabled until a valid URL is entered", %{conn: conn, book: book} do
      {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
      lv |> element("button[phx-click=open_edit]") |> render_click()
      lv |> element("button[phx-click=edit_tab][phx-value-tab=cover]") |> render_click()

      # Disabled by default (empty field)
      assert has_element?(lv, "#cover-url-form button[type=submit][disabled]")

      # Still disabled for a non-URL value
      lv |> form("#cover-url-form", %{"cover_url" => "not a url"}) |> render_change()
      assert has_element?(lv, "#cover-url-form button[type=submit][disabled]")

      # Enabled for a valid http(s) URL
      lv
      |> form("#cover-url-form", %{"cover_url" => "https://example.com/cover.jpg"})
      |> render_change()

      refute has_element?(lv, "#cover-url-form button[type=submit][disabled]")
    end

    test "uploading a cover updates the book", %{conn: conn, book: book} do
      {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
      lv |> element("button[phx-click=open_edit]") |> render_click()
      lv |> element("button[phx-click=edit_tab][phx-value-tab=cover]") |> render_click()

      image = File.read!("test/support/fixtures/images/cover.png")

      cover =
        file_input(lv, "#cover-upload-form", :cover, [
          %{name: "cover.png", content: image, type: "image/png"}
        ])

      render_upload(cover, "cover.png")
      lv |> element("#cover-upload-form") |> render_submit()

      updated = Library.get_book!(book.id)
      assert updated.cover_path
      assert File.exists?(updated.cover_path)
    end
  end

  describe "chapters tab" do
    setup %{book: book} do
      # Replace the single fixture chapter with two known ones.
      Pageless.Library.replace_chapters(book, [
        %{title: "Intro", start_seconds: 0.0},
        %{title: "Middle", start_seconds: 300.0}
      ])

      :ok
    end

    test "lists the book's chapters", %{conn: conn, book: book} do
      lv = open_chapters(conn, book)

      assert render(lv) =~ "Intro"
      assert render(lv) =~ "Middle"
      assert has_element?(lv, "#book-edit-tab-content.overflow-hidden")
      assert has_element?(lv, "#chapter-edit-layout.h-full")
      assert has_element?(lv, "#chapter-edit-list.flex-1.overflow-y-auto")
      assert has_element?(lv, "#chapter-edit-actions.shrink-0 button[phx-click=save_chapters]")
    end

    test "adding a chapter shows a new row", %{conn: conn, book: book} do
      lv = open_chapters(conn, book)

      before = lv |> render() |> count_chapter_rows()
      lv |> element("button[phx-click=add_chapter]") |> render_click()
      assert count_chapter_rows(render(lv)) == before + 1
    end

    test "added chapter starts one second after the last chapter", %{conn: conn, book: book} do
      # Last fixture chapter starts at 300s (05:00) -> new row at 05:01.
      lv = open_chapters(conn, book)
      lv |> element("button[phx-click=add_chapter]") |> render_click()

      assert render(lv) =~ ~s(value="00:05:01")
    end

    test "inserted chapter starts one second after the row above", %{conn: conn, book: book} do
      # Insert below the first chapter (starts at 0s) -> new row at 00:00:01.
      lv = open_chapters(conn, book)
      first_id = first_chapter_id(book)

      lv
      |> element("#chapter-edit-#{first_id} button[phx-click=insert_chapter_below]")
      |> render_click()

      assert render(lv) =~ ~s(value="00:00:01")
    end

    test "removing all chapters empties the list", %{conn: conn, book: book} do
      lv = open_chapters(conn, book)
      lv |> element("button[phx-click=remove_all_chapters]") |> render_click()

      assert render(lv) =~ "No chapters"
    end

    test "opens Audible lookup with the book ASIN and previews results", %{
      conn: conn,
      book: book
    } do
      {:ok, book} = Library.update_book(book, %{"asin" => "B017V4IM1G"})
      lv = open_chapters(conn, book)

      lv |> element("button[phx-click=open_chapter_lookup]") |> render_click()

      assert has_element?(lv, "#audible-chapter-lookup-modal")

      assert has_element?(
               lv,
               "#audible-chapter-lookup-form input[name='lookup[asin]'][value='B017V4IM1G']"
             )

      submit_chapter_lookup(lv, "B017V4IM1G")

      assert has_element?(lv, "#audible-chapter-results")
      assert has_element?(lv, "#audible-chapter-result-1", "Audible Chapter One")
      assert has_element?(lv, "#audible-duration-warning")
      assert has_element?(lv, "button[phx-click=apply_audible_chapters]")
      assert has_element?(lv, "button[phx-click=map_audible_chapter_titles]")
    end

    test "shows lookup errors without closing the dialog", %{conn: conn, book: book} do
      lv = open_chapters(conn, book)
      lv |> element("button[phx-click=open_chapter_lookup]") |> render_click()

      submit_chapter_lookup(lv, "0000000000")

      assert has_element?(lv, "#audible-chapter-lookup-modal")
      assert has_element?(lv, "#audible-chapter-lookup-error", "No Audible chapters were found")
    end

    test "branding removal adjusts lookup timestamps and drops the outro", %{
      conn: conn,
      book: book
    } do
      lv = open_chapters(conn, book)
      lv |> element("button[phx-click=open_chapter_lookup]") |> render_click()

      submit_chapter_lookup(lv, "B017V4IM1G", true)

      assert has_element?(lv, "#audible-chapter-result-1", "0:06")
      assert has_element?(lv, "#audible-chapter-result-2", "9:56")
      refute has_element?(lv, "#audible-chapter-result-3")
    end

    test "applies lookup chapters to edit state and persists only when saved", %{
      conn: conn,
      book: book
    } do
      lv = open_chapters(conn, book)
      lv |> element("button[phx-click=open_chapter_lookup]") |> render_click()
      submit_chapter_lookup(lv, "B017V4IM1G")

      lv |> element("button[phx-click=apply_audible_chapters]") |> render_click()

      refute has_element?(lv, "#audible-chapter-lookup-modal")
      assert has_element?(lv, "#chapter-edit-list input[value='Audible Chapter One']")

      assert has_element?(
               lv,
               "#chapter-edit-list input[aria-label='Start time'][value='00:00:10']"
             )

      assert Enum.map(Library.get_book!(book.id).chapters, & &1.title) == ["Intro", "Middle"]

      lv |> element("button[phx-click=save_chapters]") |> render_click()

      assert Enum.map(Library.get_book!(book.id).chapters, & &1.title) == [
               "Opening Credits",
               "Audible Chapter One",
               "Audible Chapter Two",
               "End Credits"
             ]

      imported =
        Enum.find(Library.get_book!(book.id).chapters, &(&1.title == "Audible Chapter One"))

      assert imported.start_seconds == 10.5
    end

    test "maps Audible titles without replacing existing timestamps", %{conn: conn, book: book} do
      lv = open_chapters(conn, book)
      lv |> element("button[phx-click=open_chapter_lookup]") |> render_click()
      submit_chapter_lookup(lv, "B017V4IM1G")

      lv |> element("button[phx-click=map_audible_chapter_titles]") |> render_click()

      assert has_element?(lv, "#chapter-edit-list input[value='Opening Credits']")
      assert has_element?(lv, "#chapter-edit-list input[value='Audible Chapter One']")

      assert has_element?(
               lv,
               "#chapter-edit-list input[aria-label='Start time'][value='00:05:00']"
             )
    end

    test "saving persists edited chapters", %{conn: conn, book: book} do
      lv = open_chapters(conn, book)

      # Edit the first chapter's title and start time via blur events.
      first = List.first(Library.get_book!(book.id).chapters)

      render_hook(lv, "update_chapter_field", %{
        "id" => first.id,
        "field" => "title",
        "value" => "Renamed Intro"
      })

      lv |> element("button[phx-click=save_chapters]") |> render_click()

      titles = Library.get_book!(book.id).chapters |> Enum.map(& &1.title)
      assert "Renamed Intro" in titles
    end

    test "insert chapter below adds a row", %{conn: conn, book: book} do
      lv = open_chapters(conn, book)

      before = lv |> render() |> count_chapter_rows()

      lv
      |> element("#chapter-edit-#{first_chapter_id(book)} button[phx-click=insert_chapter_below]")
      |> render_click()

      assert count_chapter_rows(render(lv)) == before + 1
    end

    test "play from timestamp broadcasts to the player", %{conn: conn, book: book, scope: scope} do
      Phoenix.PubSub.subscribe(Pageless.PubSub, PagelessWeb.PlayerLive.topic(scope.user.id))
      lv = open_chapters(conn, book)

      # Second chapter starts at 300s.
      second_id = Library.get_book!(book.id).chapters |> Enum.at(1) |> Map.get(:id)

      lv
      |> element("#chapter-edit-#{second_id} button[phx-click=play_chapter_edit]")
      |> render_click()

      assert_receive {:play_book, _book_id, 300.0, true}
      render_player(lv)
    end
  end

  defp open_chapters(conn, book) do
    {:ok, lv, _html} = live(conn, ~p"/books/#{book.id}")
    lv |> element("button[phx-click=open_edit]") |> render_click()
    lv |> element("button[phx-click=edit_tab][phx-value-tab=chapters]") |> render_click()
    lv
  end

  defp first_chapter_id(book) do
    Library.get_book!(book.id).chapters |> List.first() |> Map.get(:id)
  end

  defp submit_chapter_lookup(lv, asin, remove_branding? \\ false) do
    lv
    |> form("#audible-chapter-lookup-form",
      lookup: %{
        asin: asin,
        region: "us",
        remove_branding: to_string(remove_branding?)
      }
    )
    |> render_submit()

    render_async(lv, 1_000)
  end

  defp count_chapter_rows(html) do
    ~r/id="chapter-edit-/ |> Regex.scan(html) |> length()
  end

  defp live(conn, path) do
    case Phoenix.LiveViewTest.live(conn, path) do
      {:ok, view, html} ->
        render(view)
        render_player(view)
        {:ok, view, html}

      other ->
        other
    end
  end

  defp render_player(view) do
    case find_live_child(view, "player-live") do
      nil -> :ok
      player -> render(player)
    end
  end
end
