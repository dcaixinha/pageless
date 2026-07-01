defmodule Pageless.Importers.AudiobookshelfTest do
  use Pageless.DataCase, async: true

  alias Pageless.Importers.Audiobookshelf
  alias Pageless.Library
  alias Pageless.Playback.{Bookmark, ListeningSession, PlaybackProgress}

  import Pageless.AccountsFixtures
  import Pageless.LibraryFixtures

  test "dry-run reports path-mapped matches without writing" do
    user = user_fixture()
    book = book_fixture(%{folder_path: "/media/audiobooks/Author/Book"})
    audio_file_fixture(book, %{path: "/media/audiobooks/Author/Book/book.m4b"})

    snapshot = snapshot([abs_item("abs-item", "/abs/audiobooks/Author/Book")])

    assert {:ok, report} =
             Audiobookshelf.import_snapshot(snapshot,
               user: user,
               dry_run: true,
               path_maps: [{"/abs/audiobooks", "/media/audiobooks"}]
             )

    assert report.dry_run
    assert report.totals.matched == 1
    assert report.totals.unmatched == 0
    assert Repo.aggregate(PlaybackProgress, :count) == 0
  end

  test "fills blank metadata, imports progress and bookmarks" do
    user = user_fixture()

    book =
      book_fixture(%{
        title: "Existing Title",
        subtitle: nil,
        description: nil,
        publisher: nil,
        published_date: nil,
        isbn: nil,
        asin: nil,
        language: nil,
        folder_path: "/media/audiobooks/Author/Book",
        duration_seconds: 0.0
      })

    audio_file_fixture(book, %{path: "/media/audiobooks/Author/Book/book.m4b"})

    item =
      abs_item("abs-item", "/abs/audiobooks/Author/Book", %{
        "media" => %{
          "id" => "abs-book",
          "metadata" => %{
            "title" => "ABS Title",
            "subtitle" => "ABS Subtitle",
            "description" => "Description",
            "publisher" => "Publisher",
            "publishedYear" => "2020",
            "isbn" => "isbn",
            "asin" => "asin",
            "language" => "en",
            "narrators" => ["Primary Narrator", %{"name" => "Doe, Jane"}],
            "authors" => [%{"name" => "Author"}],
            "series" => [%{"name" => "Series", "sequence" => "1"}],
            "genres" => ["History:World:Civilization", "History", "World", "Civilization"]
          },
          "audioFiles" => [
            %{"metadata" => %{"path" => "/abs/audiobooks/Author/Book/book.m4b"}}
          ],
          "chapters" => [%{"title" => "Start", "start" => 0.0, "end" => 100.0}]
        }
      })

    started_at = ~U[2024-01-01 03:04:05Z] |> DateTime.to_unix(:millisecond)
    last_update = ~U[2024-01-02 03:04:05Z] |> DateTime.to_unix(:millisecond)
    finished_at = ~U[2024-01-03 03:04:05Z] |> DateTime.to_unix(:millisecond)

    snapshot = %{
      user: %{
        "mediaProgress" => [
          %{
            "libraryItemId" => "abs-item",
            "currentTime" => 100.0,
            "duration" => 100.0,
            "isFinished" => true,
            "startedAt" => started_at,
            "lastUpdate" => last_update,
            "finishedAt" => finished_at
          }
        ],
        "bookmarks" => [
          %{"libraryItemId" => "abs-item", "time" => 42.0, "title" => "Bookmark"}
        ]
      },
      items: [item],
      listening_sessions: []
    }

    assert {:ok, report} =
             Audiobookshelf.import_snapshot(snapshot,
               user: user,
               path_maps: [{"/abs/audiobooks", "/media/audiobooks"}],
               import_covers: false
             )

    assert report.imported.metadata == 1
    assert report.imported.progress == 1
    assert report.imported.bookmarks == 1

    imported = Library.get_book!(book.id)
    assert imported.title == "Existing Title"
    assert imported.subtitle == "ABS Subtitle"
    assert imported.description == "Description"

    assert Enum.map(imported.book_narrators, & &1.narrator.name) == [
             "Primary Narrator",
             "Doe, Jane"
           ]

    assert imported.publisher.name == "Publisher"
    assert imported.published_date == ~D[2020-01-01]
    assert imported.isbn == "isbn"
    assert imported.asin == "asin"
    assert imported.language == "en"
    assert Enum.map(imported.authors, & &1.name) == ["Author"]
    assert Enum.map(imported.series, & &1.name) == ["Series"]
    assert Enum.map(imported.chapters, & &1.title) == ["Start"]

    imported = Repo.preload(imported, book_series: :series)
    assert [%{series: %{name: "Series"}, sequence: "1"}] = imported.book_series

    assert Enum.sort(Enum.map(imported.genres, & &1.name)) ==
             ["Civilization", "History", "World"]

    progress = Repo.get_by!(PlaybackProgress, user_id: user.id, book_id: book.id)
    assert progress.current_seconds == 100.0
    assert progress.finished_at == ~U[2024-01-03 03:04:05Z]
    assert progress.started_at == ~U[2024-01-01 03:04:05Z]
    assert progress.last_played_at == ~U[2024-01-02 03:04:05Z]

    bookmark = Repo.get_by!(Bookmark, user_id: user.id, book_id: book.id)
    assert bookmark.position_seconds == 42.0
    assert bookmark.note == "Bookmark"
  end

  test "imports listening history only when requested" do
    user = user_fixture()
    book = book_fixture(%{folder_path: "/media/audiobooks/Author/Book"})
    audio_file_fixture(book, %{path: "/media/audiobooks/Author/Book/book.m4b"})

    session_id = Ecto.UUID.generate()
    started_at = ~U[2024-01-01 10:00:00Z] |> DateTime.to_unix(:millisecond)
    updated_at = ~U[2024-01-01 10:30:00Z] |> DateTime.to_unix(:millisecond)

    # A realistic Audiobookshelf deviceInfo blob serializes to well over the old
    # varchar(255) limit; ensure the importer can store it.
    device_info = %{
      "clientName" => "Abs iOS",
      "clientVersion" => "0.12.0-beta",
      "deviceId" => "5fde52cf39789b34",
      "deviceName" => "Google Pixel 10 Pro",
      "id" => Ecto.UUID.generate(),
      "ipAddress" => "178.166.41.134",
      "manufacturer" => "Google",
      "model" => "Pixel 10 Pro",
      "sdkVersion" => "",
      "userId" => Ecto.UUID.generate()
    }

    assert byte_size(Jason.encode!(device_info)) > 255

    snapshot = %{
      user: %{"mediaProgress" => [], "bookmarks" => []},
      items: [
        abs_item("abs-item", "/abs/audiobooks/Author/Book", %{"media" => %{"id" => "abs-book"}})
      ],
      listening_sessions: [
        %{
          "id" => session_id,
          "libraryItemId" => "abs-item",
          "bookId" => "abs-book",
          "displayTitle" => "Title",
          "displayAuthor" => "Author",
          "playMethod" => 0,
          "deviceInfo" => device_info,
          "startedAt" => started_at,
          "updatedAt" => updated_at,
          "timeListening" => 1800,
          "currentTime" => 500.0,
          "duration" => 1000.0
        }
      ]
    }

    assert {:ok, report} =
             Audiobookshelf.import_snapshot(snapshot,
               user: user,
               path_maps: [{"/abs/audiobooks", "/media/audiobooks"}],
               include_history: true,
               import_covers: false
             )

    assert report.imported.history == 1

    session = Repo.get!(ListeningSession, session_id)
    assert session.book_id == book.id
    assert session.user_id == user.id
    assert session.title == "Title"
    assert session.authors == "Author"
    assert session.time_listened_seconds == 1800
    assert session.last_position_seconds == 500.0
    assert session.device_info == Jason.encode!(device_info)
  end

  test "imports collections, mapping books by path" do
    user = user_fixture()
    library = library_fixture()
    book = book_fixture(%{library: library, folder_path: "/media/audiobooks/Author/Book"})
    audio_file_fixture(book, %{path: "/media/audiobooks/Author/Book/book.m4b"})

    collection_book =
      abs_item("abs-item", "/abs/audiobooks/Author/Book", %{"media" => %{"id" => "abs-book"}})

    snapshot = %{
      user: %{"mediaProgress" => [], "bookmarks" => []},
      items: [collection_book],
      collections: [
        %{
          "id" => Ecto.UUID.generate(),
          "name" => "Kids",
          "description" => "For the little ones",
          "libraryId" => "abs-lib",
          "books" => [collection_book]
        }
      ],
      listening_sessions: []
    }

    assert {:ok, report} =
             Audiobookshelf.import_snapshot(snapshot,
               user: user,
               path_maps: [{"/abs/audiobooks", "/media/audiobooks"}],
               import_covers: false
             )

    assert report.totals.abs_collections == 1
    assert report.imported.collections == 1

    scope = Pageless.Accounts.Scope.for_user(admin_user_fixture())
    assert [collection] = Library.list_collections(scope)
    assert collection.name == "Kids"
    assert collection.library_id == library.id
    assert Enum.map(collection.book_collections, & &1.book_id) == [book.id]
  end

  test "imports playlists for the target user, preserving order" do
    user = user_fixture()
    library = library_fixture()
    b1 = book_fixture(%{library: library, folder_path: "/media/audiobooks/A/One"})
    audio_file_fixture(b1, %{path: "/media/audiobooks/A/One/book.m4b"})
    b2 = book_fixture(%{library: library, folder_path: "/media/audiobooks/A/Two"})
    audio_file_fixture(b2, %{path: "/media/audiobooks/A/Two/book.m4b"})

    item1 = abs_item("abs-1", "/abs/audiobooks/A/One", %{"media" => %{"id" => "m1"}})
    item2 = abs_item("abs-2", "/abs/audiobooks/A/Two", %{"media" => %{"id" => "m2"}})

    snapshot = %{
      user: %{"mediaProgress" => [], "bookmarks" => []},
      items: [item1, item2],
      playlists: [
        %{
          "id" => Ecto.UUID.generate(),
          "name" => "Testtt",
          "libraryId" => "abs-lib",
          # Order: Two then One.
          "items" => [
            %{"libraryItemId" => "abs-2", "libraryItem" => item2},
            %{"libraryItemId" => "abs-1", "libraryItem" => item1}
          ]
        }
      ],
      listening_sessions: []
    }

    assert {:ok, report} =
             Audiobookshelf.import_snapshot(snapshot,
               user: user,
               path_maps: [{"/abs/audiobooks", "/media/audiobooks"}],
               import_covers: false
             )

    assert report.totals.abs_playlists == 1
    assert report.imported.playlists == 1

    scope = Pageless.Accounts.Scope.for_user(user)
    assert [playlist] = Library.list_playlists(scope)
    assert playlist.name == "Testtt"
    assert Enum.map(playlist.playlist_books, & &1.book_id) == [b2.id, b1.id]
  end

  describe "progress conflict resolution" do
    setup do
      user = user_fixture()
      book = book_fixture(%{folder_path: "/media/audiobooks/Author/Book"})
      audio_file_fixture(book, %{path: "/media/audiobooks/Author/Book/book.m4b"})

      %{user: user, book: book}
    end

    test "finished ABS data overwrites a newer, unfinished local row", %{
      user: user,
      book: book
    } do
      # Local row was touched recently (2026) but never finished.
      insert_progress(user, book,
        current_seconds: 8744.0,
        duration_seconds: 55_122.0,
        finished_at: nil,
        last_played_at: ~U[2026-07-09 11:46:36Z]
      )

      # ABS says the book was finished back in 2019.
      snapshot = finished_progress_snapshot(finished_at_ms: ~U[2019-09-15 00:00:00Z])

      assert {:ok, report} =
               Audiobookshelf.import_snapshot(snapshot,
                 user: user,
                 path_maps: [{"/abs/audiobooks", "/media/audiobooks"}],
                 import_covers: false
               )

      assert report.imported.progress == 1

      progress = Repo.get_by!(PlaybackProgress, user_id: user.id, book_id: book.id)
      assert progress.finished_at == ~U[2019-09-15 00:00:00Z]
      assert progress.last_played_at == ~U[2019-09-15 00:00:00Z]
      assert is_nil(progress.deleted_at)
    end

    test "revives a soft-deleted local row", %{user: user, book: book} do
      insert_progress(user, book,
        current_seconds: 10.0,
        duration_seconds: 100.0,
        finished_at: nil,
        last_played_at: ~U[2026-07-09 11:46:36Z],
        deleted_at: ~U[2026-07-13 14:31:24Z]
      )

      snapshot = finished_progress_snapshot(finished_at_ms: ~U[2019-09-15 00:00:00Z])

      assert {:ok, report} =
               Audiobookshelf.import_snapshot(snapshot,
                 user: user,
                 path_maps: [{"/abs/audiobooks", "/media/audiobooks"}],
                 import_covers: false
               )

      assert report.imported.progress == 1

      progress = Repo.get_by!(PlaybackProgress, user_id: user.id, book_id: book.id)
      assert is_nil(progress.deleted_at)
      assert progress.finished_at == ~U[2019-09-15 00:00:00Z]
    end

    test "keeps a newer local row when incoming ABS progress is older and unfinished", %{
      user: user,
      book: book
    } do
      insert_progress(user, book,
        current_seconds: 8744.0,
        duration_seconds: 55_122.0,
        finished_at: nil,
        last_played_at: ~U[2026-07-09 11:46:36Z]
      )

      last_update = ~U[2019-07-15 00:00:00Z] |> DateTime.to_unix(:millisecond)

      snapshot = %{
        user: %{
          "mediaProgress" => [
            %{
              "libraryItemId" => "abs-item",
              "currentTime" => 500.0,
              "duration" => 55_122.0,
              "isFinished" => false,
              "lastUpdate" => last_update
            }
          ],
          "bookmarks" => []
        },
        items: [abs_item("abs-item", "/abs/audiobooks/Author/Book")],
        listening_sessions: []
      }

      assert {:ok, report} =
               Audiobookshelf.import_snapshot(snapshot,
                 user: user,
                 path_maps: [{"/abs/audiobooks", "/media/audiobooks"}],
                 import_covers: false
               )

      assert report.imported.progress == 0

      progress = Repo.get_by!(PlaybackProgress, user_id: user.id, book_id: book.id)
      assert progress.current_seconds == 8744.0
      assert progress.last_played_at == ~U[2026-07-09 11:46:36Z]
    end
  end

  describe "select_libraries/2" do
    setup do
      libraries = [
        %{"id" => "lib-1", "name" => "Audiobooks", "mediaType" => "book"},
        %{"id" => "lib-2", "name" => "Podcasts", "mediaType" => "podcast"},
        %{"id" => "lib-3", "name" => "Books", "mediaType" => "book"}
      ]

      %{libraries: libraries}
    end

    test "returns all libraries when no filters given", %{libraries: libraries} do
      assert {:ok, ^libraries} = Audiobookshelf.select_libraries(libraries, [])
    end

    test "matches by name case-insensitively", %{libraries: libraries} do
      assert {:ok, [%{"id" => "lib-1"}]} =
               Audiobookshelf.select_libraries(libraries, ["audiobooks"])
    end

    test "matches by id", %{libraries: libraries} do
      assert {:ok, [%{"id" => "lib-3"}]} =
               Audiobookshelf.select_libraries(libraries, ["lib-3"])
    end

    test "matches multiple filters", %{libraries: libraries} do
      assert {:ok, selected} =
               Audiobookshelf.select_libraries(libraries, ["Audiobooks", "Books"])

      assert Enum.map(selected, & &1["id"]) == ["lib-1", "lib-3"]
    end

    test "errors when a filter matches nothing", %{libraries: libraries} do
      assert {:error, {:unknown_libraries, ["missing"]}} =
               Audiobookshelf.select_libraries(libraries, ["Audiobooks", "Missing"])
    end
  end

  test "report includes number of scanned libraries" do
    user = user_fixture()

    snapshot = %{
      user: %{"mediaProgress" => [], "bookmarks" => []},
      libraries: [%{"id" => "lib-1", "name" => "Audiobooks"}],
      items: []
    }

    assert {:ok, report} = Audiobookshelf.import_snapshot(snapshot, user: user, dry_run: true)
    assert report.totals.abs_libraries == 1
  end

  defp snapshot(items), do: %{user: %{"mediaProgress" => [], "bookmarks" => []}, items: items}

  defp insert_progress(user, book, attrs) do
    now = DateTime.utc_now(:second)

    row =
      %{
        id: Ecto.UUID.generate(),
        user_id: user.id,
        book_id: book.id,
        current_seconds: 0.0,
        duration_seconds: 0.0,
        finished_at: nil,
        last_played_at: now,
        deleted_at: nil,
        inserted_at: now,
        updated_at: now
      }
      |> Map.merge(Map.new(attrs))

    {1, _} = Repo.insert_all(PlaybackProgress, [row])
    :ok
  end

  defp finished_progress_snapshot(opts) do
    finished_at = Keyword.fetch!(opts, :finished_at_ms)
    finished_at_ms = DateTime.to_unix(finished_at, :millisecond)

    %{
      user: %{
        "mediaProgress" => [
          %{
            "libraryItemId" => "abs-item",
            "currentTime" => 55_122.0,
            "duration" => 55_122.0,
            "isFinished" => true,
            "lastUpdate" => finished_at_ms,
            "finishedAt" => finished_at_ms
          }
        ],
        "bookmarks" => []
      },
      items: [abs_item("abs-item", "/abs/audiobooks/Author/Book")],
      listening_sessions: []
    }
  end

  defp abs_item(id, path, overrides \\ %{}) do
    base = %{
      "id" => id,
      "mediaType" => "book",
      "path" => path,
      "media" => %{
        "id" => "media-#{id}",
        "metadata" => %{"title" => "Book"},
        "audioFiles" => [%{"metadata" => %{"path" => Path.join(path, "book.m4b")}}],
        "chapters" => []
      }
    }

    deep_merge(base, overrides)
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end
end
