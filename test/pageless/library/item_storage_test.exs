defmodule Pageless.Library.ItemStorageTest do
  use Pageless.DataCase, async: true

  import Pageless.LibraryFixtures

  alias Pageless.Library
  alias Pageless.Library.ItemStorage
  alias Pageless.Media

  setup do
    dir =
      Path.join(System.tmp_dir!(), "pageless-item-storage-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "stores covers beside books when enabled", %{dir: dir} do
    library = library_fixture(store_covers_with_item: true)
    book = book_fixture(library: library, folder_path: dir)

    assert {:ok, path} = ItemStorage.store_cover(book, "image", "png")
    assert path == Path.join(dir, "cover.png")
    assert File.read!(path) == "image"
    assert central_covers(book.id) == []
  end

  test "stores covers centrally when disabled", %{dir: dir} do
    library = library_fixture(store_covers_with_item: false)
    book = book_fixture(library: library, folder_path: dir)
    File.write!(Path.join(dir, "cover.jpg"), "stale")

    assert {:ok, path} = ItemStorage.store_cover(book, "image", "png")
    assert Path.dirname(path) == Media.covers_path()
    assert File.read!(path) == "image"
    refute File.exists?(Path.join(dir, "cover.png"))
    assert File.read!(Path.join(dir, "cover.jpg")) == "stale"

    on_exit(fn -> Media.delete_covers(book.id) end)
  end

  test "falls back to central cover storage when the item cannot be written" do
    library = library_fixture(store_covers_with_item: true)
    missing_dir = Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}")
    book = book_fixture(library: library, folder_path: missing_dir)

    assert {:ok, path} = ItemStorage.store_cover(book, "image", "jpg")
    assert Path.dirname(path) == Media.covers_path()
    assert File.read!(path) == "image"

    on_exit(fn -> Media.delete_covers(book.id) end)
  end

  test "metadata updates preserve unknown sidecar fields", %{dir: dir} do
    library = library_fixture(store_metadata_with_item: true)
    book = book_fixture(library: library, folder_path: dir)
    chapter_fixture(book)
    path = Path.join(dir, "metadata.json")

    File.write!(
      path,
      Jason.encode!(%{
        "custom" => %{"keep" => true},
        "metadata" => %{"externalField" => "kept", "title" => "Old"},
        "chapters" => [%{"id" => 42, "title" => "Old", "start" => 0, "end" => 1}]
      })
    )

    assert {:ok, _book} =
             Library.update_book(book, %{
               "title" => "Updated",
               "authors" => "First Author, Second Author",
               "narrators" => ["Reader One"]
             })

    assert {:ok, _book} =
             Library.replace_chapters(book, [%{title: "Opening", start_seconds: 0.0}])

    json = path |> File.read!() |> Jason.decode!()
    assert json["custom"] == %{"keep" => true}
    assert json["metadata"]["externalField"] == "kept"
    assert json["metadata"]["title"] == "Updated"
    assert json["metadata"]["authors"] == ["First Author", "Second Author"]
    assert json["metadata"]["narrators"] == ["Reader One"]
    assert [%{"id" => 42, "title" => "Opening"} = chapter] = json["chapters"]
    assert chapter["start"] == 0.0
  end

  test "does not write metadata when disabled", %{dir: dir} do
    library = library_fixture(store_metadata_with_item: false)
    book = book_fixture(library: library, folder_path: dir)

    assert :ok = ItemStorage.sync_metadata(book)
    refute File.exists?(Path.join(dir, "metadata.json"))
  end

  test "does not overwrite an invalid existing sidecar", %{dir: dir} do
    library = library_fixture(store_metadata_with_item: true)
    book = book_fixture(library: library, folder_path: dir)
    path = Path.join(dir, "metadata.json")
    File.write!(path, "{invalid")

    assert {:ok, _book} = Library.update_book(book, %{"title" => "Updated"})
    assert File.read!(path) == "{invalid"
  end

  defp central_covers(book_id) do
    Media.covers_path()
    |> Path.join("#{book_id}.*")
    |> Path.wildcard()
  end
end
