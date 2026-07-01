defmodule Pageless.Library.ScannerTest do
  use Pageless.DataCase, async: false

  alias Pageless.Library
  alias Pageless.Library.{Book, Scanner}
  alias Pageless.Repo

  @media_root Path.expand("../../support/fixtures/media", __DIR__)

  setup do
    {:ok, library} =
      Library.create_library(%{
        name: "Fixtures",
        media_type: "book",
        store_covers_with_item: false,
        store_metadata_with_item: false,
        folders: [%{path: @media_root}]
      })

    %{library: library}
  end

  test "discover_book_dirs/1 finds folders containing m4b files" do
    dirs = Scanner.discover_book_dirs([@media_root])
    assert Enum.any?(dirs, &String.ends_with?(&1, "The Test Book"))
  end

  test "scan/1 imports the book with sidecar metadata", %{library: library} do
    assert {:ok, %{scanned: 1, errors: 0}} = Scanner.scan(library)

    [book] = Library.list_books(library_id: library.id)
    book = Library.get_book!(book.id)

    assert book.title == "The Test Book"
    assert book.subtitle == "A Fixture for Scanning"
    assert book.publisher.name == "Pageless Press"
    assert book.published_date == ~D[2021-01-01]
    assert book.isbn == "9781234567897"
    assert book.language == "eng"
    assert book.duration_seconds > 0

    author_names = Enum.map(book.authors, & &1.name) |> Enum.sort()
    assert author_names == ["Second Author", "Test Author"]

    assert [%{name: "Test Series"}] = book.series
    assert [%{name: "Fiction"}] = book.genres
    assert [%{narrator: %{name: "Reader McRead"}, position: 0}] = book.book_narrators

    book = Pageless.Repo.preload(book, book_series: :series)
    assert [%{series: %{name: "Test Series"}, sequence: "1"}] = book.book_series
  end

  test "scan/1 creates one audio file per book", %{library: library} do
    {:ok, _} = Scanner.scan(library)
    [book] = Library.list_books(library_id: library.id)
    book = Library.get_book!(book.id)

    assert [audio] = book.audio_files
    assert audio.mime_type == "audio/mp4"
    assert String.ends_with?(audio.path, ".m4b")
    assert audio.duration_seconds > 0
  end

  test "scan/1 imports chapters from the sidecar (preferred over embedded)", %{library: library} do
    {:ok, _} = Scanner.scan(library)
    [book] = Library.list_books(library_id: library.id)
    book = Library.get_book!(book.id)

    titles = Enum.map(book.chapters, & &1.title)
    assert titles == ["Sidecar Opening", "Sidecar Closing"]
  end

  test "scan/1 is idempotent", %{library: library} do
    assert {:ok, %{scanned: 1}} = Scanner.scan(library)
    assert {:ok, %{scanned: 1}} = Scanner.scan(library)
    assert Library.count_books(library.id) == 1
  end

  test "scan/1 broadcasts progress", %{library: library} do
    Phoenix.PubSub.subscribe(Pageless.PubSub, Scanner.topic(library.id))
    Scanner.scan(library)

    assert_received {:scan_started, %{library_id: _}}
    assert_received {:scan_progress, %{total: 1}}
    assert_received {:scan_finished, %{result: %{scanned: 1}}}
  end

  test "written sidecars preserve cleared metadata on rescan" do
    root = Path.join(System.tmp_dir!(), "pageless-scanner-#{System.unique_integer([:positive])}")
    book_dir = Path.join(root, "The Test Book")
    File.mkdir_p!(book_dir)

    fixture_dir = Path.join(@media_root, "The Test Book")

    File.cp!(
      Path.join(fixture_dir, "The Test Book.m4b"),
      Path.join(book_dir, "The Test Book.m4b")
    )

    File.cp!(Path.join(fixture_dir, "metadata.json"), Path.join(book_dir, "metadata.json"))
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, library} =
      Library.create_library(%{
        name: "Writable",
        media_type: "book",
        store_covers_with_item: true,
        store_metadata_with_item: true,
        folders: [%{path: root}]
      })

    assert {:ok, %{scanned: 1, errors: 0}} = Scanner.scan(library)
    [book] = Library.list_books(library_id: library.id)

    assert {:ok, _book} =
             Library.update_book(book, %{
               "authors" => "",
               "narrators" => [],
               "genres" => "",
               "publisher" => "",
               "description" => ""
             })

    assert {:ok, _book} = Library.replace_chapters(book, [])
    assert {:ok, %{scanned: 1, errors: 0}} = Scanner.scan(library)

    rescanned = Library.get_book!(book.id)
    assert rescanned.authors == []
    assert rescanned.book_narrators == []
    assert rescanned.genres == []
    assert rescanned.publisher == nil
    assert rescanned.description == nil
    assert rescanned.chapters == []
  end

  test "external sidecar changes update existing book metadata" do
    %{library: library, book_dir: book_dir, audio_path: audio_path} = writable_library_fixture()
    assert {:ok, %{scanned: 1}} = Scanner.scan(library)
    [book] = Library.list_books(library_id: library.id)

    path = Path.join(book_dir, "metadata.json")
    json = path |> File.read!() |> Jason.decode!()
    File.write!(path, Jason.encode!(put_in(json, ["metadata", "title"], "Externally Updated")))

    assert {:ok, %{scanned: 1, errors: 0}} = Scanner.scan(library)
    assert Library.get_book!(book.id).title == "Externally Updated"

    rewrite_embedded_title(audio_path, "Embedded Update")
    assert {:ok, %{scanned: 1, errors: 0}} = Scanner.scan(library)
    assert Library.get_book!(book.id).title == "Externally Updated"
  end

  test "embedded metadata changes replace scanner-generated sidecars" do
    %{library: library, book_dir: book_dir, audio_path: audio_path} = writable_library_fixture()
    File.rm!(Path.join(book_dir, "metadata.json"))
    assert {:ok, %{scanned: 1}} = Scanner.scan(library)
    [book] = Library.list_books(library_id: library.id)
    assert Repo.get!(Book, book.id).generated_metadata_hash

    rewrite_embedded_title(audio_path, "Embedded Update")

    assert {:ok, %{scanned: 1, errors: 0}} = Scanner.scan(library)
    assert Library.get_book!(book.id).title == "Embedded Update"
  end

  test "invalid sidecars preserve the existing catalog metadata" do
    %{library: library, book_dir: book_dir} = writable_library_fixture()
    assert {:ok, %{scanned: 1}} = Scanner.scan(library)
    [book] = Library.list_books(library_id: library.id)
    File.write!(Path.join(book_dir, "metadata.json"), "{invalid")

    assert {:ok, %{scanned: 1, errors: 0}} = Scanner.scan(library)
    assert Library.get_book!(book.id).title == "The Test Book"
  end

  test "removed and restored audio marks a book missing without changing its id" do
    %{library: library, book_dir: book_dir, audio_path: audio_path, fixture_audio: fixture_audio} =
      writable_library_fixture()

    assert {:ok, %{scanned: 1}} = Scanner.scan(library)
    [book] = Library.list_books(library_id: library.id)

    File.rm!(audio_path)
    assert {:ok, %{missing: 1}} = Scanner.scan(library)
    assert Library.get_book(book.id) == nil
    assert Repo.get!(Book, book.id).missing_since

    File.cp!(fixture_audio, audio_path)
    assert {:ok, %{scanned: 1}} = Scanner.scan(library)
    assert Library.get_book!(book.id).missing_since == nil
    assert Library.get_book!(book.id).folder_path == book_dir
  end

  test "renaming an item folder preserves the book id" do
    %{library: library, book_dir: book_dir} = writable_library_fixture()
    assert {:ok, %{scanned: 1}} = Scanner.scan(library)
    [book] = Library.list_books(library_id: library.id)
    renamed_dir = Path.join(Path.dirname(book_dir), "Renamed Book")
    File.rename!(book_dir, renamed_dir)

    assert {:ok, %{scanned: 1, missing: 0}} = Scanner.scan(library)
    assert Library.get_book!(book.id).folder_path == renamed_dir
    assert Library.count_books(library.id) == 1
  end

  test "moving a configured library root preserves book ids" do
    %{library: library, root: root} = writable_library_fixture()
    assert {:ok, %{scanned: 1}} = Scanner.scan(library)
    [book] = Library.list_books(library_id: library.id)
    moved_root = root <> "-moved"
    File.rename!(root, moved_root)
    on_exit(fn -> File.rm_rf!(moved_root) end)

    library = Library.get_library!(library.id)

    assert {:ok, updated_library} =
             Library.update_library(library, %{
               name: library.name,
               folders: [%{path: moved_root}]
             })

    assert {:ok, %{scanned: 1}} = Scanner.scan(updated_library)
    assert Library.get_book!(book.id).folder_path == Path.join(moved_root, "The Test Book")
    assert Library.count_books(library.id) == 1
  end

  defp writable_library_fixture do
    root = Path.join(System.tmp_dir!(), "pageless-scanner-#{System.unique_integer([:positive])}")
    book_dir = Path.join(root, "The Test Book")
    File.mkdir_p!(book_dir)
    fixture_dir = Path.join(@media_root, "The Test Book")
    fixture_audio = Path.join(fixture_dir, "The Test Book.m4b")
    audio_path = Path.join(book_dir, "The Test Book.m4b")
    File.cp!(fixture_audio, audio_path)
    File.cp!(Path.join(fixture_dir, "metadata.json"), Path.join(book_dir, "metadata.json"))
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, library} =
      Library.create_library(%{
        name: "Writable",
        media_type: "book",
        store_covers_with_item: true,
        store_metadata_with_item: true,
        folders: [%{path: root}]
      })

    %{
      library: library,
      root: root,
      book_dir: book_dir,
      audio_path: audio_path,
      fixture_audio: fixture_audio
    }
  end

  defp rewrite_embedded_title(audio_path, title) do
    output = "#{audio_path}.updated.m4b"

    {_output, 0} =
      System.cmd("ffmpeg", [
        "-v",
        "quiet",
        "-y",
        "-i",
        audio_path,
        "-c",
        "copy",
        "-metadata",
        "title=#{title}",
        output
      ])

    File.rename!(output, audio_path)
  end
end
