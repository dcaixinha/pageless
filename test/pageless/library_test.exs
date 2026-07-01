defmodule Pageless.LibraryTest do
  use Pageless.DataCase, async: true

  alias Pageless.{Accounts, Library}
  alias Pageless.Library.BookSeries
  alias Pageless.Library.Library, as: LibrarySchema
  alias Pageless.Playback
  alias Pageless.Playback.PlaybackProgress
  alias Pageless.Repo

  import Pageless.AccountsFixtures
  import Pageless.LibraryFixtures

  describe "libraries" do
    test "create_library/1 with valid data and folders" do
      assert {:ok, %LibrarySchema{} = library} =
               Library.create_library(%{
                 name: "Audiobooks",
                 media_type: "book",
                 folders: [%{path: "/data/audiobooks"}]
               })

      assert library.name == "Audiobooks"
      assert library.store_covers_with_item
      assert library.store_metadata_with_item
      assert library.auto_scan_on_file_changes
      assert [folder] = library.folders
      assert folder.path == "/data/audiobooks"
    end

    test "update_library/2 persists item storage settings" do
      library = library_fixture()

      assert {:ok, updated} =
               Library.update_library(library, %{
                 name: "Updated",
                 store_covers_with_item: false,
                 store_metadata_with_item: false,
                 auto_scan_on_file_changes: false
               })

      assert updated.name == "Updated"
      refute updated.store_covers_with_item
      refute updated.store_metadata_with_item
      refute updated.auto_scan_on_file_changes
    end

    test "update_library/2 marks books from removed roots unavailable" do
      library = library_fixture(%{folders: [%{path: "/old"}]})
      book = book_fixture(%{library: library, folder_path: "/old/Book"})
      library = Library.get_library!(library.id)

      assert {:ok, _updated} =
               Library.update_library(library, %{
                 name: library.name,
                 folders: [%{path: "/new"}]
               })

      assert Library.get_book(book.id) == nil
      assert Repo.get!(Pageless.Library.Book, book.id).missing_since
    end

    test "changeset casts item storage settings" do
      changeset =
        LibrarySchema.changeset(%LibrarySchema{}, %{
          name: "Library",
          store_covers_with_item: false,
          store_metadata_with_item: false
        })

      assert Ecto.Changeset.get_change(changeset, :store_covers_with_item) == false
      assert Ecto.Changeset.get_change(changeset, :store_metadata_with_item) == false
    end

    test "create_library/1 rejects invalid media_type" do
      assert {:error, changeset} =
               Library.create_library(%{name: "X", media_type: "video"})

      assert "is invalid" in errors_on(changeset).media_type
    end

    test "list_libraries/0 orders by name and preloads folders" do
      library_fixture(%{name: "Zeta"})
      library_fixture(%{name: "Alpha"})

      assert [%{name: "Alpha"}, %{name: "Zeta"}] = Library.list_libraries()
    end

    test "delete_library/1 cascades to books" do
      library = library_fixture()
      book = book_fixture(%{library: library})

      assert {:ok, _} = Library.delete_library(library)
      refute Library.get_book(book.id)
    end
  end

  describe "books" do
    test "list_books/1 filters by library" do
      lib1 = library_fixture()
      lib2 = library_fixture()
      book_fixture(%{library: lib1, title: "A"})
      book_fixture(%{library: lib2, title: "B"})

      titles = Library.list_books(library_id: lib1.id) |> Enum.map(& &1.title)
      assert titles == ["A"]
    end

    test "list_books/1 searches by title and author" do
      library = library_fixture()
      book = book_fixture(%{library: library, title: "The Hobbit"})
      author = Library.upsert_author("J.R.R. Tolkien")

      book
      |> Pageless.Repo.preload(:authors)
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_assoc(:authors, [author])
      |> Pageless.Repo.update!()

      {:ok, :ok} = Library.replace_book_narrators(book, ["Andy Serkis"])
      {:ok, _book} = Library.update_book(book, %{"publisher" => "HarperCollins"})

      book_fixture(%{library: library, title: "Dune"})

      assert [%{title: "The Hobbit"}] = Library.list_books(search: "hobbit")
      assert [%{title: "The Hobbit"}] = Library.list_books(search: "tolkien")
      assert [%{title: "The Hobbit"}] = Library.list_books(search: "serkis")
      assert [%{title: "The Hobbit"}] = Library.list_books(search: "harper")
    end

    test "list_books/1 sorts by title and duration in both directions" do
      library = library_fixture()
      book_fixture(%{library: library, title: "beta", duration_seconds: 100.0})
      book_fixture(%{library: library, title: "Alpha", duration_seconds: 999.0})

      assert ["Alpha", "beta"] = Library.list_books(sort: :title) |> Enum.map(& &1.title)

      assert ["beta", "Alpha"] =
               Library.list_books(sort: :title, sort_direction: :desc) |> Enum.map(& &1.title)

      assert ["Alpha", "beta"] = Library.list_books(sort: :duration) |> Enum.map(& &1.title)

      assert ["beta", "Alpha"] =
               Library.list_books(sort: :duration, sort_direction: :asc) |> Enum.map(& &1.title)
    end

    test "list_books/2 ignores title prefixes for users who enable the preference" do
      user = admin_user_fixture()

      {:ok, user} =
        Accounts.update_player_settings(user, %{"ignore_prefixes_when_sorting" => true})

      scope = user_scope_fixture(user)
      library = library_fixture()
      book_fixture(%{library: library, title: "The Apple"})
      book_fixture(%{library: library, title: "Banana"})
      book_fixture(%{library: library, title: "A Zebra"})
      book_fixture(%{library: library, title: "An Orange"})
      book_fixture(%{library: library, title: "Theology"})

      assert ["The Apple", "Banana", "An Orange", "Theology", "A Zebra"] =
               Library.list_books(scope, sort: :title) |> Enum.map(& &1.title)

      assert ["A Zebra", "Theology", "An Orange", "Banana", "The Apple"] =
               Library.list_books(scope, sort: :title, sort_direction: :desc)
               |> Enum.map(& &1.title)

      assert ["The Apple", "Banana", "An Orange", "Theology", "A Zebra"] =
               Library.list_books(scope, sort: :duration) |> Enum.map(& &1.title)
    end

    test "list_books/1 sorts by author name in first-last and last-first order" do
      library = library_fixture()
      zoe = Library.upsert_author("Zoe de la Cruz")
      amy = Library.upsert_author("Amy Smith")

      book_fixture(%{library: library, title: "Zoe's Book"}) |> attach(:authors, zoe)
      book_fixture(%{library: library, title: "Amy's Book"}) |> attach(:authors, amy)
      book_fixture(%{library: library, title: "No Author"})

      assert ["Amy's Book", "Zoe's Book", "No Author"] =
               Library.list_books(sort: :author_first, sort_direction: :asc)
               |> Enum.map(& &1.title)

      assert ["Zoe's Book", "Amy's Book", "No Author"] =
               Library.list_books(sort: :author_last, sort_direction: :asc)
               |> Enum.map(& &1.title)
    end

    test "list_books/1 sorts nullable metadata with missing values last" do
      library = library_fixture()

      book_fixture(%{
        library: library,
        title: "Older",
        published_date: ~D[1990-01-01],
        size: 100,
        mtime: ~U[2020-01-01 00:00:00Z]
      })

      book_fixture(%{
        library: library,
        title: "Newer",
        published_date: ~D[2020-01-01],
        size: 200,
        mtime: ~U[2024-01-01 00:00:00Z]
      })

      book_fixture(%{library: library, title: "Missing"})

      assert ["Newer", "Older", "Missing"] = sorted_titles(:published)
      assert ["Older", "Newer", "Missing"] = sorted_titles(:size, :asc)
      assert ["Newer", "Older", "Missing"] = sorted_titles(:modified)
    end

    test "list_books/2 sorts progress by the scoped user's timestamps" do
      scope = admin_user_fixture() |> user_scope_fixture()
      library = library_fixture()
      earlier = book_fixture(%{library: library, title: "Earlier"})
      later = book_fixture(%{library: library, title: "Later"})
      missing = book_fixture(%{library: library, title: "Missing"})

      earlier_progress = Playback.save_progress(scope, earlier.id, 100.0, 1000.0)
      later_progress = Playback.save_progress(scope, later.id, 100.0, 1000.0)

      Repo.update_all(
        from(p in PlaybackProgress, where: p.id == ^earlier_progress.id),
        set: [updated_at: ~U[2024-01-01 00:00:00Z]]
      )

      Repo.update_all(
        from(p in PlaybackProgress, where: p.id == ^later_progress.id),
        set: [updated_at: ~U[2025-01-01 00:00:00Z]]
      )

      assert [later.id, earlier.id, missing.id] ==
               Library.list_books(scope, sort: :progress_updated)
               |> Enum.map(& &1.id)
    end

    test "list_books/2 combines facet filters with OR within and AND across categories" do
      scope = admin_user_fixture() |> user_scope_fixture()
      library = library_fixture(name: "Main")
      other_library = library_fixture(name: "Other")
      fantasy = Library.upsert_genre("Fantasy")
      history = Library.upsert_genre("History")
      author_a = Library.upsert_author("Author A")
      author_b = Library.upsert_author("Author B")
      series = Library.upsert_series("The Saga")
      narrator = Library.upsert_narrator("Narrator A")
      publisher = Library.upsert_publisher("Publisher A")

      first =
        book_fixture(%{library: library, title: "First", language: "English"})
        |> attach(:authors, author_a)

      first = attach(first, :genres, fantasy)
      attach_series(first, series)
      {:ok, :ok} = Library.replace_book_narrators(first, [narrator.name])
      {:ok, _book} = Library.update_book(first, %{"publisher" => publisher.name})
      collection = Library.upsert_collection(library.id, "Favorites")
      {:ok, _collection} = Library.add_book_to_collection(scope, collection.id, first.id)
      {:ok, playlist} = Library.create_playlist(scope, "Listen next")
      {:ok, _playlist} = Library.add_book_to_playlist(scope, playlist.id, first.id)
      other_scope = user_scope_fixture(user_fixture())
      {:ok, other_playlist} = Library.create_playlist(other_scope, "Private")
      {:ok, _playlist} = Library.add_book_to_playlist(other_scope, other_playlist.id, first.id)

      book_fixture(%{library: library, title: "Second"})
      |> attach(:authors, author_b)
      |> attach(:genres, fantasy)

      book_fixture(%{library: library, title: "Third"})
      |> attach(:authors, author_a)
      |> attach(:genres, history)

      book_fixture(%{library: other_library, title: "Elsewhere"})
      |> attach(:authors, author_a)
      |> attach(:genres, fantasy)

      assert ["First", "Second"] =
               Library.list_books(scope,
                 author_ids: [author_a.id, author_b.id],
                 genre_ids: [fantasy.id],
                 library_ids: [library.id]
               )
               |> Enum.map(& &1.title)

      assert [%{title: "First"}] = Library.list_books(scope, series_ids: [series.id])
      assert [%{title: "First"}] = Library.list_books(scope, narrator_ids: [narrator.id])
      assert [%{title: "First"}] = Library.list_books(scope, publisher_ids: [publisher.id])
      assert [%{title: "First"}] = Library.list_books(scope, collection_ids: [collection.id])
      assert [%{title: "First"}] = Library.list_books(scope, playlist_ids: [playlist.id])
      assert [%{title: "First"}] = Library.list_books(scope, languages: ["English"])
      assert [] = Library.list_books(scope, playlist_ids: [other_playlist.id])

      assert %{
               collections: [%{name: "Favorites"}],
               playlists: [%{name: "Listen next"}],
               languages: [%{name: "English"}]
             } =
               Library.book_filter_options(scope)
    end

    test "list_books/2 filters user progress and treats tombstones as not started" do
      scope = admin_user_fixture() |> user_scope_fixture()
      library = library_fixture()
      book_fixture(%{library: library, title: "Not started"})
      in_progress = book_fixture(%{library: library, title: "In progress"})
      finished = book_fixture(%{library: library, title: "Finished"})
      tombstoned = book_fixture(%{library: library, title: "Tombstoned"})

      Playback.save_progress(scope, in_progress.id, 100.0, 1000.0)
      Playback.mark_finished(scope, finished.id, 1000.0)
      Playback.save_progress(scope, tombstoned.id, 100.0, 1000.0)
      Playback.delete_progress(scope, tombstoned.id)

      assert ["In progress"] = titles_for_progress(scope, :in_progress)
      assert ["Finished"] = titles_for_progress(scope, :finished)
      assert ["Not started", "Tombstoned"] = titles_for_progress(scope, :not_started)
    end

    test "book_filter_options/1 returns represented metadata in name order" do
      scope = admin_user_fixture() |> user_scope_fixture()
      library = library_fixture(name: "Audiobooks")
      author = Library.upsert_author("An Author")
      genre = Library.upsert_genre("A Genre")
      series = Library.upsert_series("A Series")
      Library.upsert_author("Unused Author")

      book =
        book_fixture(%{library: library}) |> attach(:authors, author) |> attach(:genres, genre)

      attach_series(book, series)

      assert %{
               authors: [%{id: author_id, name: "An Author", book_count: 1}],
               genres: [%{id: genre_id, name: "A Genre", book_count: 1}],
               series: [%{id: series_id, name: "A Series", book_count: 1}],
               libraries: [%{id: library_id, name: "Audiobooks", book_count: 1}]
             } = Library.book_filter_options(scope)

      assert author_id == author.id
      assert genre_id == genre.id
      assert series_id == series.id
      assert library_id == library.id
    end

    test "book filters and options do not expose inaccessible libraries" do
      visible_library = library_fixture(name: "Visible")
      hidden_library = library_fixture(name: "Hidden")
      visible_author = Library.upsert_author("Visible Author")
      hidden_author = Library.upsert_author("Hidden Author")

      visible_book =
        book_fixture(%{library: visible_library, title: "Visible Book"})
        |> attach(:authors, visible_author)

      {:ok, :ok} = Library.replace_book_narrators(visible_book, ["Visible Narrator"])
      {:ok, _book} = Library.update_book(visible_book, %{"publisher" => "Visible Publisher"})

      hidden_book =
        book_fixture(%{library: hidden_library, title: "Hidden Book"})
        |> attach(:authors, hidden_author)

      {:ok, :ok} = Library.replace_book_narrators(hidden_book, ["Hidden Narrator"])
      {:ok, _book} = Library.update_book(hidden_book, %{"publisher" => "Hidden Publisher"})

      admin_scope = admin_user_fixture() |> user_scope_fixture()

      {:ok, user} =
        Accounts.create_managed_user(admin_scope, %{
          email: unique_user_email(),
          password: valid_user_password(),
          permissions: %{can_access_all_libraries: false},
          library_ids: [visible_library.id]
        })

      scope = user_scope_fixture(user)

      assert %{
               authors: [%{id: visible_author_id, book_count: 1}],
               libraries: [%{id: visible_library_id, book_count: 1}]
             } =
               Library.book_filter_options(scope)

      assert visible_author_id == visible_author.id
      assert visible_library_id == visible_library.id
      assert [%{id: ^visible_library_id}] = Library.list_libraries(scope)
      assert Library.list_narrator_names(scope) == ["Visible Narrator"]
      assert Library.list_publisher_names(scope) == ["Visible Publisher"]
      assert [%{id: visible_book_id}] = Library.list_books(scope, author_ids: [visible_author.id])
      assert visible_book_id == visible_book.id
      assert [] = Library.list_books(scope, author_ids: [hidden_author.id])
    end

    test "get_book!/1 preloads audio files and chapters ordered" do
      book = book_fixture()
      audio_file_fixture(book)
      chapter_fixture(book, %{index: 1, title: "Two", start_seconds: 600.0, end_seconds: 1200.0})
      chapter_fixture(book, %{index: 0, title: "One", start_seconds: 0.0, end_seconds: 600.0})

      loaded = Library.get_book!(book.id)
      assert length(loaded.audio_files) == 1
      assert Enum.map(loaded.chapters, & &1.title) == ["One", "Two"]
    end

    test "upsert_author/1 is idempotent" do
      a1 = Library.upsert_author("Same Name")
      a2 = Library.upsert_author("Same Name")
      assert a1.id == a2.id
    end

    test "upsert_genre/1 is idempotent" do
      g1 = Library.upsert_genre("History")
      g2 = Library.upsert_genre("History")
      assert g1.id == g2.id
    end
  end

  describe "update_book/2" do
    test "updates editable details" do
      book = book_fixture(%{title: "Old"})

      assert {:ok, updated} =
               Library.update_book(book, %{
                 "title" => "New Title",
                 "subtitle" => "A Subtitle",
                 "published_date" => "2020-03-15"
               })

      assert updated.title == "New Title"
      assert updated.subtitle == "A Subtitle"
      assert updated.published_date == ~D[2020-03-15]
    end

    test "sets and orders narrators without splitting commas" do
      book = book_fixture()

      assert {:ok, _updated} =
               Library.update_book(book, %{
                 "narrators" => ["Doe, Jane", "Second Reader", "DOE, JANE"]
               })

      assert ["Doe, Jane", "Second Reader"] =
               Library.get_book!(book.id).book_narrators
               |> Enum.map(& &1.narrator.name)

      assert {:ok, _updated} = Library.update_book(book, %{"narrators" => ["Replacement"]})

      assert [%{narrator: %{name: "Replacement"}, position: 0}] =
               Library.get_book!(book.id).book_narrators
    end

    test "sets, reuses, and clears a singular publisher" do
      first = book_fixture()
      second = book_fixture()

      assert {:ok, updated} = Library.update_book(first, %{"publisher" => "Pageless Press"})
      assert updated.publisher.name == "Pageless Press"

      assert {:ok, updated_second} =
               Library.update_book(second, %{"publisher" => "PAGELESS PRESS"})

      assert updated_second.publisher_id == updated.publisher_id

      assert {:ok, cleared} = Library.update_book(updated, %{"publisher" => ""})
      assert cleared.publisher == nil
    end

    test "sets authors from a comma-separated string" do
      book = book_fixture()

      assert {:ok, updated} =
               Library.update_book(book, %{"authors" => "First Author, Second Author"})

      names = Library.get_book!(updated.id).authors |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["First Author", "Second Author"]
    end

    test "sets genres from a separated string" do
      book = book_fixture()

      assert {:ok, updated} =
               Library.update_book(book, %{"genres" => "History, Science / Biography:World"})

      names = Library.get_book!(updated.id).genres |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["Biography", "History", "Science", "World"]
    end

    test "replaces existing authors" do
      book = book_fixture()
      {:ok, _} = Library.update_book(book, %{"authors" => "Original"})
      {:ok, updated} = Library.update_book(book, %{"authors" => "Replacement"})

      names = Library.get_book!(updated.id).authors |> Enum.map(& &1.name)
      assert names == ["Replacement"]
    end

    test "sets series with a sequence and drops numberless entries" do
      book = book_fixture()

      # "Standalone Saga" has no #number, so it must be dropped (a book in a
      # series always needs a sequence).
      {:ok, _} =
        Library.update_book(book, %{"series" => "Uma Aventura #3, Standalone Saga"})

      loaded = Library.get_book!(book.id) |> Pageless.Repo.preload(book_series: :series)
      entries = Enum.map(loaded.book_series, &{&1.series.name, &1.sequence})
      assert entries == [{"Uma Aventura", "3"}]
    end

    test "replaces existing series" do
      book = book_fixture()
      {:ok, _} = Library.update_book(book, %{"series" => "First #1"})
      {:ok, _} = Library.update_book(book, %{"series" => "Second #2"})

      loaded = Library.get_book!(book.id) |> Pageless.Repo.preload(book_series: :series)
      assert Enum.map(loaded.book_series, & &1.series.name) == ["Second"]
      assert Enum.map(loaded.book_series, & &1.sequence) == ["2"]
    end

    test "clearing the series field removes all series" do
      book = book_fixture()
      {:ok, _} = Library.update_book(book, %{"series" => "Only #1"})
      {:ok, _} = Library.update_book(book, %{"series" => ""})

      loaded = Library.get_book!(book.id) |> Pageless.Repo.preload(:book_series)
      assert loaded.book_series == []
    end

    test "sets collections scoped to the book's library" do
      library = library_fixture()
      book = book_fixture(%{library: library})

      {:ok, _} = Library.update_book(book, %{"collections" => "Favourites, Kids"})

      loaded = Library.get_book!(book.id) |> Pageless.Repo.preload(book_collections: :collection)
      names = Enum.map(loaded.book_collections, & &1.collection.name) |> Enum.sort()
      assert names == ["Favourites", "Kids"]
      assert Enum.all?(loaded.book_collections, &(&1.collection.library_id == library.id))
    end

    test "replaces existing collections" do
      library = library_fixture()
      book = book_fixture(%{library: library})
      {:ok, _} = Library.update_book(book, %{"collections" => "Old"})
      {:ok, _} = Library.update_book(book, %{"collections" => "New"})

      loaded = Library.get_book!(book.id) |> Pageless.Repo.preload(book_collections: :collection)
      assert Enum.map(loaded.book_collections, & &1.collection.name) == ["New"]
    end

    test "requires a title" do
      book = book_fixture()
      assert {:error, changeset} = Library.update_book(book, %{"title" => ""})
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects an invalid publish date" do
      book = book_fixture()
      assert {:error, changeset} = Library.update_book(book, %{"published_date" => "not-a-date"})
      assert %{published_date: [_]} = errors_on(changeset)
    end
  end

  describe "series browsing" do
    import Pageless.AccountsFixtures

    test "list_series/1 groups books under shared series" do
      library = library_fixture()
      b1 = book_fixture(%{library: library, title: "Book One"})
      b2 = book_fixture(%{library: library, title: "Book Two"})

      Library.set_book_series(b1, [%{name: "Saga", sequence: "1"}])
      Library.set_book_series(b2, [%{name: "Saga", sequence: "2"}])

      scope = user_scope_fixture(admin_user_fixture())
      assert [series] = Library.list_series(scope)
      assert series.name == "Saga"
      assert Enum.map(series.book_series, & &1.book.title) == ["Book One", "Book Two"]
    end

    test "set_book_series/2 ignores entries without a sequence number" do
      book = book_fixture()

      Library.set_book_series(book, [
        %{name: "Numbered", sequence: "1"},
        %{name: "Numberless", sequence: nil},
        %{name: "Blank", sequence: "  "}
      ])

      loaded = Library.get_book!(book.id) |> Pageless.Repo.preload(book_series: :series)
      assert Enum.map(loaded.book_series, & &1.series.name) == ["Numbered"]
    end

    test "get_series/2 orders books numerically by sequence" do
      library = library_fixture()
      b1 = book_fixture(%{library: library, title: "Second"})
      b2 = book_fixture(%{library: library, title: "Tenth"})
      b3 = book_fixture(%{library: library, title: "First"})

      Library.set_book_series(b1, [%{name: "Saga", sequence: "2"}])
      Library.set_book_series(b2, [%{name: "Saga", sequence: "10"}])
      Library.set_book_series(b3, [%{name: "Saga", sequence: "1"}])

      scope = user_scope_fixture(admin_user_fixture())
      [series] = Library.list_series(scope)

      loaded = Library.get_series(scope, series.id)
      assert Enum.map(loaded.book_series, & &1.book.title) == ["First", "Second", "Tenth"]
    end

    test "get_series/2 returns nil for an unknown id" do
      scope = user_scope_fixture(admin_user_fixture())
      assert Library.get_series(scope, Ecto.UUID.generate()) == nil
    end

    test "add_book_to_series/4 adds a book with its sequence" do
      scope = user_scope_fixture(admin_user_fixture())
      library = library_fixture()
      existing = book_fixture(%{library: library, title: "First"})
      Library.set_book_series(existing, [%{name: "Saga", sequence: "1"}])
      [series] = Library.list_series(scope)

      new_book = book_fixture(%{library: library, title: "Second"})
      assert {:ok, _} = Library.add_book_to_series(scope, series.id, new_book.id, "2")

      loaded = Library.get_series(scope, series.id)
      entries = Enum.map(loaded.book_series, &{&1.book.title, &1.sequence})
      assert entries == [{"First", "1"}, {"Second", "2"}]
    end

    test "add_book_to_series/4 requires a sequence" do
      scope = user_scope_fixture(admin_user_fixture())
      library = library_fixture()
      seed = book_fixture(%{library: library})
      Library.set_book_series(seed, [%{name: "Saga", sequence: "1"}])
      [series] = Library.list_series(scope)
      book = book_fixture(%{library: library})

      assert {:error, :missing_sequence} =
               Library.add_book_to_series(scope, series.id, book.id, "")

      assert {:error, :missing_sequence} =
               Library.add_book_to_series(scope, series.id, book.id, "   ")
    end

    test "add_book_to_series/4 updates the sequence when the book is already present" do
      scope = user_scope_fixture(admin_user_fixture())
      library = library_fixture()
      book = book_fixture(%{library: library})
      Library.set_book_series(book, [%{name: "Saga", sequence: "1"}])
      [series] = Library.list_series(scope)

      assert {:ok, _} = Library.add_book_to_series(scope, series.id, book.id, "5")

      loaded = Library.get_series(scope, series.id)
      assert [%{sequence: "5"}] = loaded.book_series
    end

    test "remove_book_from_series/3 removes a book" do
      scope = user_scope_fixture(admin_user_fixture())
      library = library_fixture()
      b1 = book_fixture(%{library: library, title: "One"})
      b2 = book_fixture(%{library: library, title: "Two"})
      Library.set_book_series(b1, [%{name: "Saga", sequence: "1"}])
      Library.set_book_series(b2, [%{name: "Saga", sequence: "2"}])
      [series] = Library.list_series(scope)

      assert {:ok, _} = Library.remove_book_from_series(scope, series.id, b1.id)

      loaded = Library.get_series(scope, series.id)
      assert Enum.map(loaded.book_series, & &1.book.title) == ["Two"]
    end
  end

  describe "collections" do
    import Pageless.AccountsFixtures

    test "upsert_collection/3 creates then updates by (library, name)" do
      library = library_fixture()

      c1 = Library.upsert_collection(library.id, "Kids", %{description: "First"})
      assert c1.name == "Kids"
      assert c1.description == "First"

      c2 = Library.upsert_collection(library.id, "Kids", %{description: "Updated"})
      assert c2.id == c1.id
      assert c2.description == "Updated"
    end

    test "set_collection_books/2 sets ordered membership" do
      library = library_fixture()
      b1 = book_fixture(%{library: library})
      b2 = book_fixture(%{library: library})
      collection = Library.upsert_collection(library.id, "Kids")

      Library.set_collection_books(collection, [b2.id, b1.id])

      scope = user_scope_fixture(admin_user_fixture())
      loaded = Library.get_collection(scope, collection.id)
      assert Enum.map(loaded.book_collections, & &1.book_id) == [b2.id, b1.id]
      assert Enum.map(loaded.book_collections, & &1.position) == [0, 1]
    end

    test "list_collections/1 returns collections for accessible libraries" do
      library = library_fixture()
      Library.upsert_collection(library.id, "Kids")

      scope = user_scope_fixture(admin_user_fixture())
      assert [%{name: "Kids"}] = Library.list_collections(scope)
    end

    test "add/remove book keeps order and is idempotent" do
      scope = user_scope_fixture(admin_user_fixture())
      library = library_fixture()
      b1 = book_fixture(%{library: library})
      b2 = book_fixture(%{library: library})
      collection = Library.upsert_collection(library.id, "Kids")

      {:ok, _} = Library.add_book_to_collection(scope, collection.id, b1.id)
      {:ok, _} = Library.add_book_to_collection(scope, collection.id, b2.id)
      {:ok, _} = Library.add_book_to_collection(scope, collection.id, b1.id)

      loaded = Library.get_collection(scope, collection.id)
      assert Enum.map(loaded.book_collections, & &1.book_id) == [b1.id, b2.id]

      {:ok, _} = Library.remove_book_from_collection(scope, collection.id, b1.id)
      loaded = Library.get_collection(scope, collection.id)
      assert Enum.map(loaded.book_collections, & &1.book_id) == [b2.id]
    end

    test "add_book_to_collection/3 rejects a book from another library" do
      scope = user_scope_fixture(admin_user_fixture())
      lib_a = library_fixture()
      lib_b = library_fixture()
      collection = Library.upsert_collection(lib_a.id, "Kids")
      book = book_fixture(%{library: lib_b})

      assert {:error, :wrong_library} =
               Library.add_book_to_collection(scope, collection.id, book.id)
    end
  end

  describe "playlists" do
    import Pageless.AccountsFixtures

    test "create_playlist/2 and list_playlists/1 are user-scoped" do
      s1 = user_scope_fixture(user_fixture())
      s2 = user_scope_fixture(user_fixture())

      {:ok, _} = Library.create_playlist(s1, "Mine")

      assert [%{name: "Mine"}] = Library.list_playlists(s1)
      assert Library.list_playlists(s2) == []
    end

    test "create_playlist/2 rejects a duplicate name for the same user" do
      scope = user_scope_fixture(user_fixture())
      {:ok, _} = Library.create_playlist(scope, "Dupe")
      assert {:error, _} = Library.create_playlist(scope, "Dupe")
    end

    test "add/remove book keeps order and is idempotent" do
      scope = user_scope_fixture(user_fixture())
      library = library_fixture()
      b1 = book_fixture(%{library: library})
      b2 = book_fixture(%{library: library})
      {:ok, playlist} = Library.create_playlist(scope, "List")

      {:ok, _} = Library.add_book_to_playlist(scope, playlist.id, b1.id)
      {:ok, _} = Library.add_book_to_playlist(scope, playlist.id, b2.id)
      # Duplicate add is a no-op.
      {:ok, _} = Library.add_book_to_playlist(scope, playlist.id, b1.id)

      loaded = Library.get_playlist(scope, playlist.id)
      assert Enum.map(loaded.playlist_books, & &1.book_id) == [b1.id, b2.id]

      {:ok, _} = Library.remove_book_from_playlist(scope, playlist.id, b1.id)
      loaded = Library.get_playlist(scope, playlist.id)
      assert Enum.map(loaded.playlist_books, & &1.book_id) == [b2.id]
    end

    test "get_playlist/2 does not leak other users' playlists" do
      owner = user_scope_fixture(user_fixture())
      other = user_scope_fixture(user_fixture())
      {:ok, playlist} = Library.create_playlist(owner, "Private")

      assert Library.get_playlist(other, playlist.id) == nil
    end

    test "playlist reads exclude books from inaccessible libraries" do
      visible_library = library_fixture()
      hidden_library = library_fixture()
      visible_book = book_fixture(%{library: visible_library})
      hidden_book = book_fixture(%{library: hidden_library})
      admin_scope = user_scope_fixture(admin_user_fixture())

      {:ok, user} =
        Accounts.create_managed_user(admin_scope, %{
          email: unique_user_email(),
          password: valid_user_password(),
          permissions: %{can_access_all_libraries: false},
          library_ids: [visible_library.id]
        })

      scope = user_scope_fixture(user)
      {:ok, playlist} = Library.create_playlist(scope, "Scoped")
      Library.set_playlist_books(playlist, [visible_book.id, hidden_book.id])

      assert [loaded] = Library.list_playlists(scope)
      assert Enum.map(loaded.playlist_books, & &1.book_id) == [visible_book.id]
    end

    test "add_book_to_playlist/3 fails for a playlist the user does not own" do
      owner = user_scope_fixture(user_fixture())
      other = user_scope_fixture(user_fixture())
      book = book_fixture()
      {:ok, playlist} = Library.create_playlist(owner, "Owned")

      assert {:error, :not_found} =
               Library.add_book_to_playlist(other, playlist.id, book.id)
    end
  end

  describe "replace_chapters/2" do
    test "creates chapters with derived end times and indexes" do
      book = book_fixture(%{duration_seconds: 1000.0})

      assert {:ok, updated} =
               Library.replace_chapters(book, [
                 %{title: "One", start_seconds: 0.0},
                 %{title: "Two", start_seconds: 400.0}
               ])

      [c1, c2] = updated.chapters
      assert {c1.title, c1.start_seconds, c1.end_seconds, c1.index} == {"One", 0.0, 400.0, 0}
      assert {c2.title, c2.start_seconds, c2.end_seconds, c2.index} == {"Two", 400.0, 1000.0, 1}
    end

    test "sorts chapters by start time" do
      book = book_fixture(%{duration_seconds: 1000.0})

      {:ok, updated} =
        Library.replace_chapters(book, [
          %{title: "Later", start_seconds: 500.0},
          %{title: "Earlier", start_seconds: 100.0}
        ])

      assert Enum.map(updated.chapters, & &1.title) == ["Earlier", "Later"]
    end

    test "replaces existing chapters" do
      book = book_fixture(%{duration_seconds: 1000.0})
      chapter_fixture(book, %{title: "Old", start_seconds: 0.0, end_seconds: 1000.0, index: 0})

      {:ok, updated} = Library.replace_chapters(book, [%{title: "New", start_seconds: 0.0}])
      assert Enum.map(updated.chapters, & &1.title) == ["New"]
    end

    test "supports removing all chapters" do
      book = book_fixture(%{duration_seconds: 1000.0})
      chapter_fixture(book, %{title: "A", start_seconds: 0.0, end_seconds: 1000.0, index: 0})

      {:ok, updated} = Library.replace_chapters(book, [])
      assert updated.chapters == []
    end

    test "blank titles become nil" do
      book = book_fixture(%{duration_seconds: 1000.0})
      {:ok, updated} = Library.replace_chapters(book, [%{title: "  ", start_seconds: 0.0}])
      assert [%{title: nil}] = updated.chapters
    end
  end

  describe "set_cover_from_file/2" do
    test "stores the cover and updates cover_path" do
      book = book_fixture()

      src = Path.join(System.tmp_dir!(), "src_#{System.unique_integer([:positive])}.png")
      File.write!(src, "image-bytes")
      on_exit(fn -> File.rm(src) end)
      on_exit(fn -> Pageless.Media.delete_covers(book.id) end)

      assert {:ok, updated} = Library.set_cover_from_file(book, src)
      assert updated.cover_path
      assert File.read!(updated.cover_path) == "image-bytes"
      assert String.contains?(updated.cover_path, book.id)
    end
  end

  defp attach(book, association, entity) do
    book
    |> Repo.preload(association)
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(association, [entity])
    |> Repo.update!()
  end

  defp attach_series(book, series) do
    %BookSeries{}
    |> BookSeries.changeset(%{book_id: book.id, series_id: series.id, sequence: "1"})
    |> Repo.insert!()
  end

  defp titles_for_progress(scope, progress) do
    scope
    |> Library.list_books(progress: [progress])
    |> Enum.map(& &1.title)
  end

  defp sorted_titles(sort, direction \\ :desc) do
    Library.list_books(sort: sort, sort_direction: direction) |> Enum.map(& &1.title)
  end
end
