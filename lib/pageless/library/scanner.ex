defmodule Pageless.Library.Scanner do
  @moduledoc """
  Scans library folders for audiobooks.

  For v1 each book is a folder (or the library root) containing a single
  `.m4b` audio file, an optional cover image, and an optional Audiobookshelf
  `metadata.json` sidecar.

  Metadata precedence (highest first): `metadata.json` sidecar, embedded
  ffprobe tags, then the folder name.

  Scans run inside a `Task` supervised by `Pageless.ScannerSupervisor` and
  broadcast progress over PubSub on the `"library_scan:<library_id>"` topic.
  """

  require Logger
  import Ecto.Query

  alias Pageless.Repo
  alias Pageless.Library
  alias Pageless.Library.{AudioFile, Book, Chapter, Events, ItemStorage, Probe, Sidecar}
  alias Pageless.Media

  @audio_exts ~w(.m4b)
  @cover_names ~w(cover.jpg cover.jpeg cover.png cover.webp folder.jpg)

  @doc "PubSub topic for a library's scan progress."
  def topic(library_id), do: "library_scan:#{library_id}"

  @doc """
  Starts an asynchronous scan of the given library under the scanner
  supervisor. Returns `{:ok, pid}`.
  """
  def scan_async(library) do
    Pageless.Library.ScanCoordinator.request_scan(library, :manual)
    {:ok, :queued}
  end

  @doc """
  Synchronously scans a library. Returns `{:ok, %{scanned: n, errors: m}}`.
  """
  def scan(library, opts \\ []) do
    library = Repo.preload(library, :folders)
    folders = Enum.map(library.folders, & &1.path)
    {book_dirs, healthy_roots} = discover_book_dirs_with_health(folders)
    total = length(book_dirs)
    broadcast(library.id, {:scan_started, %{library_id: library.id, total: total}})

    {book_ids, errors} =
      book_dirs
      |> Enum.with_index(1)
      |> Enum.reduce({[], 0}, fn {dir, idx}, {book_ids, errors} ->
        broadcast(
          library.id,
          {:scan_progress, %{library_id: library.id, current: idx, total: total, path: dir}}
        )

        case scan_book_dir(library, dir, Keyword.get(opts, :force_audio_metadata, false)) do
          {:ok, book} ->
            {[book.id | book_ids], errors}

          {:error, reason} ->
            Logger.warning("Failed to scan #{dir}: #{inspect(reason)}")
            {book_ids, errors + 1}
        end
      end)

    missing_book_ids =
      if Keyword.get(opts, :reconcile_missing, true),
        do: reconcile_missing_books(library.id, book_dirs, healthy_roots),
        else: []

    book_ids = Enum.reverse(book_ids)
    Events.broadcast_changed(library.id, book_ids, missing_book_ids)

    result = %{
      scanned: length(book_ids),
      errors: errors,
      missing: length(missing_book_ids),
      total: total
    }

    broadcast(library.id, {:scan_finished, %{library_id: library.id, result: result}})
    {:ok, result}
  end

  @doc """
  Returns the list of directories that look like books (contain an `.m4b`).
  Exposed for testing.
  """
  def discover_book_dirs(folders) do
    folders
    |> Enum.flat_map(&find_book_dirs/1)
    |> Enum.uniq()
  end

  defp discover_book_dirs_with_health(folders) do
    folders
    |> Enum.reduce({[], []}, fn root, {dirs, healthy_roots} ->
      root = Path.expand(root)

      case walk_safe(root) do
        {:ok, root_dirs} ->
          book_dirs = Enum.filter(root_dirs, &has_audio?/1)
          {book_dirs ++ dirs, [root | healthy_roots]}

        {:error, reason} ->
          Logger.warning("Could not scan library root #{root}: #{inspect(reason)}")
          {dirs, healthy_roots}
      end
    end)
    |> then(fn {dirs, roots} -> {dirs |> Enum.uniq() |> Enum.sort(), Enum.reverse(roots)} end)
  end

  defp walk_safe(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.reduce_while({:ok, [dir]}, fn child, {:ok, dirs} ->
          case walk_safe(child) do
            {:ok, child_dirs} -> {:cont, {:ok, child_dirs ++ dirs}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_book_dirs(root) do
    if File.dir?(root) do
      root
      |> walk()
      |> Enum.filter(&has_audio?/1)
    else
      []
    end
  end

  # Recursively collect all directories under root (including root).
  defp walk(dir) do
    children =
      case File.ls(dir) do
        {:ok, entries} ->
          entries
          |> Enum.map(&Path.join(dir, &1))
          |> Enum.filter(&File.dir?/1)
          |> Enum.flat_map(&walk/1)

        {:error, _} ->
          []
      end

    [dir | children]
  end

  defp has_audio?(dir), do: audio_files_in(dir) != []

  defp audio_files_in(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(fn p ->
          File.regular?(p) and String.downcase(Path.extname(p)) in @audio_exts
        end)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp scan_book_dir(library, dir, force_audio_metadata?) do
    audio_files = audio_files_in(dir)

    with [audio_path | _] <- audio_files,
         {:ok, stat} <- File.stat(audio_path, time: :posix),
         {:ok, probe} <- Probe.probe(audio_path) do
      existing_book = find_existing_book(library.id, dir, source_identity(stat), stat.size)
      audio_changed? = force_audio_metadata? or audio_changed?(existing_book, stat)

      with {:ok, sidecar, generated_metadata?} <-
             read_sidecar(Path.join(dir, "metadata.json"), existing_book, audio_changed?) do
        attrs = build_book_attrs(dir, audio_path, probe, sidecar, stat)

        upsert_book(
          library,
          existing_book,
          audio_path,
          probe,
          sidecar,
          stat,
          attrs,
          audio_changed?,
          generated_metadata?
        )
      end
    else
      [] -> {:error, :no_audio}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_sidecar(path, existing_book, audio_changed?) do
    case Sidecar.read_result(path) do
      {:ok, sidecar} ->
        generated_file? =
          not is_nil(existing_book.generated_metadata_hash) and
            existing_book.generated_metadata_hash == ItemStorage.file_hash(path)

        if generated_file? and audio_changed?,
          do: {:ok, nil, true},
          else: {:ok, sidecar, !!generated_file?}

      :missing ->
        {:ok, nil, true}

      {:error, reason} ->
        Logger.warning("Ignoring invalid sidecar #{path}: #{inspect(reason)}")

        if existing_book.id do
          {:ok, sidecar_from_book(load_book_for_sidecar(existing_book.id)), false}
        else
          {:ok, nil, false}
        end
    end
  end

  defp load_book_for_sidecar(book_id) do
    Book
    |> Repo.get!(book_id)
    |> Repo.preload([
      :authors,
      :genres,
      :publisher,
      :chapters,
      book_narrators: :narrator,
      book_series: :series
    ])
  end

  defp sidecar_from_book(book) do
    %{
      present:
        MapSet.new(
          ~w(title subtitle description authors genres narrators series publisher published_date isbn asin language chapters)a
        ),
      title: book.title,
      subtitle: book.subtitle,
      description: book.description,
      authors: Enum.map(book.authors, & &1.name),
      genres: Enum.map(book.genres, & &1.name),
      narrators: Enum.map(book.book_narrators, & &1.narrator.name),
      series: Enum.map(book.book_series, &%{name: &1.series.name, sequence: &1.sequence}),
      publisher: book.publisher && book.publisher.name,
      published_date: book.published_date,
      isbn: book.isbn,
      asin: book.asin,
      language: book.language,
      chapters:
        Enum.map(book.chapters, &%{title: &1.title, start: &1.start_seconds, end: &1.end_seconds})
    }
  end

  defp audio_changed?(%Book{id: nil}, _stat), do: true

  defp audio_changed?(book, stat) do
    book.mtime != DateTime.from_unix!(stat.mtime) or book.size != stat.size
  end

  defp build_book_attrs(dir, _audio_path, probe, sidecar, stat) do
    sidecar = sidecar || %{}
    tags = probe.tags
    folder_name = Path.basename(dir)

    %{
      title: first_present([Map.get(sidecar, :title), tags["title"], tags["album"], folder_name]),
      subtitle: sidecar_or(sidecar, :subtitle, fn -> first_present([tags["subtitle"]]) end),
      description:
        sidecar_or(sidecar, :description, fn ->
          first_present([tags["description"], tags["comment"]])
        end),
      published_date:
        sidecar_or(sidecar, :published_date, fn ->
          Pageless.Library.PublishedDate.parse(tags["date"] || tags["year"])
        end),
      isbn: sidecar_or(sidecar, :isbn, fn -> first_present([tags["isbn"]]) end),
      asin: sidecar_or(sidecar, :asin, fn -> first_present([tags["asin"]]) end),
      language: sidecar_or(sidecar, :language, fn -> first_present([tags["language"]]) end),
      duration_seconds: probe.duration || 0.0,
      folder_path: dir,
      mtime: DateTime.from_unix!(stat.mtime),
      size: stat.size,
      scanned_at: DateTime.utc_now(:second),
      missing_since: nil,
      source_identity: source_identity(stat)
    }
  end

  defp upsert_book(
         library,
         existing_book,
         audio_path,
         probe,
         sidecar,
         stat,
         attrs,
         audio_changed?,
         generated_metadata?
       ) do
    Repo.transaction(fn ->
      book =
        existing_book
        |> Book.changeset(attrs)
        |> Ecto.Changeset.put_change(:library_id, library.id)
        |> Repo.insert_or_update!()

      replace_audio_files(book, audio_path, probe, stat)
      replace_chapters(book, probe, sidecar)
      associate_metadata(book, sidecar, probe.tags)
      maybe_extract_cover(book, attrs.folder_path, audio_path, audio_changed?)

      Library.get_book!(book.id)
    end)
    |> case do
      {:ok, book} ->
        if generated_metadata?, do: ItemStorage.sync_metadata(book, generated: true)
        {:ok, book}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_existing_book(library_id, dir, source_identity, size) do
    folder_book = Library.get_book_by_folder(library_id, dir)
    identity_book = find_book_by_source_identity(library_id, source_identity, size)

    cond do
      folder_book && is_nil(folder_book.missing_since) -> folder_book
      identity_book -> identity_book
      folder_book -> folder_book
      true -> %Book{library_id: library_id}
    end
  end

  defp find_book_by_source_identity(_library_id, nil, _size), do: nil

  defp find_book_by_source_identity(library_id, source_identity, size) do
    recent_missing = DateTime.add(DateTime.utc_now(:second), -3600, :second)

    Book
    |> where(
      [b],
      b.library_id == ^library_id and b.source_identity == ^source_identity and
        b.size == ^size and (is_nil(b.missing_since) or b.missing_since >= ^recent_missing)
    )
    |> Repo.all()
    |> case do
      [book] -> book
      _books -> nil
    end
  end

  defp source_identity(stat) do
    inode = Map.get(stat, :inode)

    if is_integer(inode) and inode > 0 do
      major = Map.get(stat, :major_device, 0)
      minor = Map.get(stat, :minor_device, 0)
      "#{major}:#{minor}:#{inode}"
    end
  end

  defp reconcile_missing_books(library_id, discovered_dirs, healthy_roots) do
    discovered = MapSet.new(Enum.map(discovered_dirs, &Path.expand/1))
    now = DateTime.utc_now(:second)

    Book
    |> where(library_id: ^library_id)
    |> Repo.all()
    |> Enum.reduce([], fn book, missing_ids ->
      path = Path.expand(book.folder_path)

      in_healthy_root? =
        Enum.any?(healthy_roots, &(path == &1 or String.starts_with?(path, &1 <> "/")))

      if in_healthy_root? and not MapSet.member?(discovered, path) and is_nil(book.missing_since) do
        book |> Ecto.Changeset.change(missing_since: now) |> Repo.update!()
        [book.id | missing_ids]
      else
        missing_ids
      end
    end)
    |> Enum.reverse()
  end

  defp replace_audio_files(book, audio_path, probe, stat) do
    Repo.delete_all(from a in AudioFile, where: a.book_id == ^book.id)

    %AudioFile{book_id: book.id}
    |> AudioFile.changeset(%{
      path: audio_path,
      index: 0,
      duration_seconds: probe.duration || 0.0,
      codec: probe.codec,
      bitrate: probe.bitrate,
      mime_type: "audio/mp4",
      size: stat.size
    })
    |> Repo.insert!()
  end

  defp replace_chapters(book, probe, sidecar) do
    Repo.delete_all(from c in Chapter, where: c.book_id == ^book.id)

    raw =
      cond do
        sidecar_present?(sidecar, :chapters) -> sidecar.chapters
        probe.chapters != [] -> probe.chapters
        true -> synthesize_chapters(probe.duration || 0.0)
      end

    raw
    |> Enum.with_index()
    |> Enum.each(fn {ch, idx} ->
      %Chapter{book_id: book.id}
      |> Chapter.changeset(%{
        title: ch[:title] || "Chapter #{idx + 1}",
        start_seconds: ch.start,
        end_seconds: ch.end,
        index: idx
      })
      |> Repo.insert!()
    end)
  end

  defp synthesize_chapters(duration) when duration <= 0.0, do: []
  defp synthesize_chapters(duration), do: [%{title: nil, start: 0.0, end: duration}]

  defp associate_metadata(book, sidecar, tags) do
    sidecar = sidecar || %{}

    author_names =
      if sidecar_present?(sidecar, :authors) do
        sidecar.authors
      else
        to_list(tags["artist"]) ++ to_list(tags["album_artist"])
      end
      |> Enum.uniq()

    authors = Enum.map(author_names, &Library.upsert_author/1)
    genres = Enum.map(genre_names(sidecar, tags), &Library.upsert_genre/1)
    narrator_names = narrator_names(sidecar, tags)

    publisher_name =
      sidecar_or(sidecar, :publisher, fn -> first_present([tags["publisher"]]) end)

    publisher = publisher_name && Library.upsert_publisher(publisher_name)
    series_entries = Map.get(sidecar, :series, [])

    book =
      book
      |> Repo.preload([:authors, :genres, :publisher])
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_assoc(:authors, authors)
      |> Ecto.Changeset.put_assoc(:genres, genres)
      |> Ecto.Changeset.put_assoc(:publisher, publisher)
      |> Repo.update!()

    Library.replace_book_narrators(book, narrator_names)

    # Series carry a per-book sequence on the join row (which `put_assoc` cannot
    # set), and a book in a series must have a number, so replace the full set
    # via the context, which enforces/filters the sequence.
    Library.replace_book_series(book, series_entries)
    book
  end

  defp narrator_names(sidecar, tags) do
    if sidecar_present?(sidecar, :narrators) do
      sidecar.narrators
    else
      case first_present([tags["composer"], tags["narrator"]]) do
        nil -> []
        name -> [name]
      end
    end
  end

  defp genre_names(sidecar, tags) do
    names =
      if sidecar_present?(sidecar, :genres),
        do: sidecar.genres,
        else: to_list(tags["genre"]) ++ to_list(tags["genres"])

    split_genres(names)
  end

  defp sidecar_or(sidecar, key, fallback) do
    if sidecar_present?(sidecar, key), do: Map.get(sidecar, key), else: fallback.()
  end

  defp sidecar_present?(sidecar, key) do
    MapSet.member?(Map.get(sidecar || %{}, :present, MapSet.new()), key)
  end

  defp split_genres(names) do
    names
    |> Enum.flat_map(&split_genre/1)
    |> Enum.uniq()
  end

  defp split_genre(name) when is_binary(name) do
    name
    |> String.split([",", ";", "/", ":"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_genre(_), do: []

  defp maybe_extract_cover(book, dir, audio_path, audio_changed?) do
    case find_cover_image(dir) do
      {:ok, src} ->
        generated_cover? =
          not is_nil(book.generated_cover_hash) and
            book.generated_cover_hash == ItemStorage.file_hash(src)

        if generated_cover? and audio_changed? do
          extract_embedded_cover(book, audio_path)
        else
          {:ok, dest} = ItemStorage.copy_cover(book, src)
          set_cover(book, dest, if(generated_cover?, do: book.generated_cover_hash))
        end

      :none ->
        extract_embedded_cover(book, audio_path)
    end
  end

  defp extract_embedded_cover(book, audio_path) do
    extracted_path =
      Path.join(
        Media.covers_path(),
        "#{book.id}-extract-#{System.unique_integer([:positive])}.jpg"
      )

    case Probe.extract_cover(audio_path, extracted_path) do
      :ok ->
        {:ok, stored_path} = ItemStorage.copy_cover(book, extracted_path)
        File.rm(extracted_path)
        set_cover(book, stored_path, ItemStorage.file_hash(stored_path))

      {:error, _} ->
        File.rm(extracted_path)

        if book.generated_cover_hash && book.cover_path &&
             book.generated_cover_hash == ItemStorage.file_hash(book.cover_path) do
          File.rm(book.cover_path)
        end

        Media.delete_covers(book.id)
        set_cover(book, nil, nil)
    end
  end

  defp set_cover(book, path, generated_hash) do
    book
    |> Book.changeset(%{cover_path: path, generated_cover_hash: generated_hash})
    |> Ecto.Changeset.force_change(:updated_at, DateTime.utc_now(:second))
    |> Repo.update!()
  end

  defp find_cover_image(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        named =
          Enum.find(entries, fn e -> String.downcase(e) in @cover_names end)

        image =
          named ||
            Enum.find(entries, fn e ->
              String.downcase(Path.extname(e)) in ~w(.jpg .jpeg .png .webp)
            end)

        if image, do: {:ok, Path.join(dir, image)}, else: :none

      {:error, _} ->
        :none
    end
  end

  defp first_present(values) do
    Enum.find_value(values, fn
      nil -> nil
      "" -> nil
      v when is_binary(v) -> (String.trim(v) != "" && String.trim(v)) || nil
      v -> v
    end)
  end

  defp to_list(nil), do: []
  defp to_list(str) when is_binary(str), do: str |> String.split(",") |> Enum.map(&String.trim/1)

  defp broadcast(library_id, message) do
    Phoenix.PubSub.broadcast(Pageless.PubSub, topic(library_id), message)
    Phoenix.PubSub.broadcast(Pageless.PubSub, "library_scans", message)
  end
end
