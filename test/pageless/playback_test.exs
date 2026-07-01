defmodule Pageless.PlaybackTest do
  use Pageless.DataCase, async: true

  doctest Pageless.Playback

  alias Pageless.Playback

  import Pageless.AccountsFixtures
  import Pageless.LibraryFixtures

  setup do
    scope = user_scope_fixture()
    book = book_fixture(%{duration_seconds: 1000.0})
    %{scope: scope, book: book}
  end

  test "save_progress/4 upserts a single row", %{scope: scope, book: book} do
    assert progress = Playback.save_progress(scope, book.id, 120.0, 1000.0)
    assert progress.current_seconds == 120.0

    updated = Playback.save_progress(scope, book.id, 240.0, 1000.0)
    assert updated.current_seconds == 240.0
    assert updated.id == progress.id
  end

  test "save_progress/4 sets started_at once and preserves it", %{scope: scope, book: book} do
    progress = Playback.save_progress(scope, book.id, 120.0, 1000.0)
    assert progress.started_at

    updated = Playback.save_progress(scope, book.id, 240.0, 1000.0)
    assert updated.started_at == progress.started_at
  end

  test "resume_position/2 returns saved position or 0", %{scope: scope, book: book} do
    assert Playback.resume_position(scope, book.id) == 0.0
    Playback.save_progress(scope, book.id, 333.0, 1000.0)
    assert Playback.resume_position(scope, book.id) == 333.0
  end

  test "delete_progress/2 removes the record", %{scope: scope, book: book} do
    Playback.save_progress(scope, book.id, 333.0, 1000.0)
    assert Playback.get_progress(scope, book.id)

    assert :ok = Playback.delete_progress(scope, book.id)
    refute Playback.get_progress(scope, book.id)
  end

  test "delete_progress/2 is a no-op when there is no record", %{scope: scope, book: book} do
    assert :ok = Playback.delete_progress(scope, book.id)
  end

  test "delete_progress/2 soft-deletes: tombstone in changes_since, hidden from reads", %{
    scope: scope,
    book: book
  } do
    Playback.save_progress(scope, book.id, 333.0, 1000.0)
    :ok = Playback.delete_progress(scope, book.id)

    refute Playback.get_progress(scope, book.id)
    assert [tomb] = Playback.changes_since(scope, nil)
    assert tomb.book_id == book.id
    assert tomb.deleted_at
  end

  test "save_progress after delete revives the tombstone", %{scope: scope, book: book} do
    Playback.save_progress(scope, book.id, 100.0, 1000.0)
    :ok = Playback.delete_progress(scope, book.id)
    refute Playback.get_progress(scope, book.id)

    revived = Playback.save_progress(scope, book.id, 200.0, 1000.0)
    assert is_nil(revived.deleted_at)
    assert revived.current_seconds == 200.0
  end

  test "save_progress/4 marks finished near the end", %{scope: scope, book: book} do
    progress = Playback.save_progress(scope, book.id, 990.0, 1000.0)
    assert Playback.finished?(progress)

    unfinished = Playback.save_progress(scope, book.id, 100.0, 1000.0)
    refute Playback.finished?(unfinished)
  end

  test "progress_by_book/1 maps book_id to progress", %{scope: scope, book: book} do
    Playback.save_progress(scope, book.id, 50.0, 1000.0)
    map = Playback.progress_by_book(scope)
    assert map[book.id].current_seconds == 50.0
  end

  test "mark_finished/3 creates progress for an unstarted book", %{scope: scope, book: book} do
    assert Playback.get_progress(scope, book.id) == nil

    progress = Playback.mark_finished(scope, book.id, book.duration_seconds)
    assert Playback.finished?(progress)
    assert progress.finished_at
    assert progress.current_seconds == 1000.0
  end

  test "mark_finished/3 finishes an in-progress book", %{scope: scope, book: book} do
    started = Playback.save_progress(scope, book.id, 100.0, 1000.0)
    refute Playback.finished?(started)

    progress = Playback.mark_finished(scope, book.id, book.duration_seconds)
    assert Playback.finished?(progress)
    # Keeps the original start time
    assert progress.inserted_at == started.inserted_at
  end

  test "mark_not_finished/2 clears the finished state", %{scope: scope, book: book} do
    Playback.mark_finished(scope, book.id, book.duration_seconds)
    progress = Playback.mark_not_finished(scope, book.id)

    refute Playback.finished?(progress)
    assert progress.finished_at == nil
  end

  test "mark_not_finished/2 is a no-op when there is no progress", %{scope: scope, book: book} do
    assert Playback.mark_not_finished(scope, book.id) == nil
  end

  test "finished books are excluded from continue_listening", %{scope: scope, book: book} do
    Playback.save_progress(scope, book.id, 100.0, 1000.0)
    assert [{_book, _p}] = Playback.continue_listening(scope)

    Playback.mark_finished(scope, book.id, book.duration_seconds)
    assert Playback.continue_listening(scope) == []
    assert [{_book, _p}] = Playback.finished_books(scope)
  end

  describe "upsert_progress/3 (sync)" do
    test "inserts when no record exists", %{scope: scope, book: book} do
      assert {:ok, p} =
               Playback.upsert_progress(scope, book.id, %{
                 current_seconds: 200.0,
                 duration_seconds: 1000.0,
                 last_played_at: DateTime.utc_now()
               })

      assert p.current_seconds == 200.0
      refute p.finished_at
    end

    test "returns :not_found for a missing book", %{scope: scope} do
      assert {:error, :not_found} =
               Playback.upsert_progress(scope, Ecto.UUID.generate(), %{
                 current_seconds: 1.0,
                 duration_seconds: 1000.0
               })
    end

    test "newer update wins over stored record", %{scope: scope, book: book} do
      old = DateTime.utc_now() |> DateTime.add(-100, :second)

      Playback.upsert_progress(scope, book.id, %{
        current_seconds: 100.0,
        duration_seconds: 1000.0,
        last_played_at: old
      })

      new = DateTime.utc_now()

      {:ok, p} =
        Playback.upsert_progress(scope, book.id, %{
          current_seconds: 500.0,
          duration_seconds: 1000.0,
          last_played_at: new
        })

      assert p.current_seconds == 500.0
    end

    test "stale update is ignored (last-write-wins)", %{scope: scope, book: book} do
      now = DateTime.utc_now()

      Playback.upsert_progress(scope, book.id, %{
        current_seconds: 800.0,
        duration_seconds: 1000.0,
        last_played_at: now
      })

      stale = DateTime.add(now, -3600, :second)

      {:ok, p} =
        Playback.upsert_progress(scope, book.id, %{
          current_seconds: 100.0,
          duration_seconds: 1000.0,
          last_played_at: stale
        })

      assert p.current_seconds == 800.0
    end

    test "derives finished_at from the winning position", %{scope: scope, book: book} do
      {:ok, p} =
        Playback.upsert_progress(scope, book.id, %{
          current_seconds: 999.0,
          duration_seconds: 1000.0,
          last_played_at: DateTime.utc_now()
        })

      assert p.finished_at
      assert Playback.finished?(p)
    end
  end

  describe "changes_since/2" do
    test "nil returns all records", %{scope: scope, book: book} do
      Playback.save_progress(scope, book.id, 10.0, 1000.0)
      assert [_] = Playback.changes_since(scope, nil)
    end

    test "filters by updated_at", %{scope: scope, book: book} do
      Playback.save_progress(scope, book.id, 10.0, 1000.0)
      future = DateTime.utc_now() |> DateTime.add(3600, :second)
      assert Playback.changes_since(scope, future) == []
    end

    test "is scoped to the user", %{scope: scope, book: book} do
      Playback.save_progress(scope, book.id, 10.0, 1000.0)
      other = user_scope_fixture()
      assert Playback.changes_since(other, nil) == []
    end
  end

  describe "bookmarks" do
    test "create/list bookmarks ordered by position", %{scope: scope, book: book} do
      {:ok, _} = Playback.create_bookmark(scope, book.id, 300.0, "later")
      {:ok, _} = Playback.create_bookmark(scope, book.id, 120.0, "earlier")

      bookmarks = Playback.list_bookmarks(scope, book.id)
      assert Enum.map(bookmarks, & &1.position_seconds) == [120.0, 300.0]
      assert Enum.map(bookmarks, & &1.note) == ["earlier", "later"]
    end

    test "create_bookmark blank note becomes nil, clamps negative position", %{
      scope: scope,
      book: book
    } do
      {:ok, bookmark} = Playback.create_bookmark(scope, book.id, -5.0, "   ")
      assert bookmark.note == nil
      assert bookmark.position_seconds == 0.0
    end

    test "delete_bookmark removes only the owner's bookmark", %{scope: scope, book: book} do
      {:ok, bookmark} = Playback.create_bookmark(scope, book.id, 100.0, nil)
      other = user_scope_fixture()

      # Another user can't delete it.
      assert :ok = Playback.delete_bookmark(other, bookmark.id)
      assert [_] = Playback.list_bookmarks(scope, book.id)

      # The owner can.
      assert :ok = Playback.delete_bookmark(scope, bookmark.id)
      assert Playback.list_bookmarks(scope, book.id) == []
    end

    test "delete_bookmark soft-deletes: tombstone appears in the sync feed", %{
      scope: scope,
      book: book
    } do
      {:ok, bookmark} = Playback.create_bookmark(scope, book.id, 100.0, nil)
      :ok = Playback.delete_bookmark(scope, bookmark.id)

      # Excluded from the active per-book list...
      assert Playback.list_bookmarks(scope, book.id) == []
      # ...but present (as a tombstone) in the full sync feed.
      assert [tomb] = Playback.list_all_bookmarks(scope)
      assert tomb.id == bookmark.id
      assert tomb.deleted_at
    end

    test "upsert_bookmark revives a tombstoned id", %{scope: scope, book: book} do
      id = Ecto.UUID.generate()
      {:ok, _} = Playback.upsert_bookmark(scope, id, book.id, 10.0, "a")
      :ok = Playback.delete_bookmark(scope, id)
      assert Playback.list_bookmarks(scope, book.id) == []

      {:ok, revived} = Playback.upsert_bookmark(scope, id, book.id, 20.0, "b")
      assert is_nil(revived.deleted_at)
      assert [%{id: ^id, note: "b"}] = Playback.list_bookmarks(scope, book.id)
    end

    test "bookmarks are scoped per user", %{scope: scope, book: book} do
      {:ok, _} = Playback.create_bookmark(scope, book.id, 100.0, nil)
      other = user_scope_fixture()
      assert Playback.list_bookmarks(other, book.id) == []
    end
  end
end
