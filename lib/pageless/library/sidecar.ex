defmodule Pageless.Library.Sidecar do
  @moduledoc """
  Parses the Audiobookshelf-style `metadata.json` sidecar file that may sit
  alongside an audiobook. The parser is intentionally lenient: it tolerates
  fields being absent, nested under a `"metadata"` key, or expressed as either
  strings or objects.
  """

  require Logger

  @doc """
  Reads and parses a `metadata.json` file. Returns a normalized map of
  metadata, or `nil` if the file is missing or invalid.

  Normalized keys:

      %{
        title: binary | nil,
        subtitle: binary | nil,
        description: binary | nil,
        authors: [binary],
        genres: [binary],
        narrators: [binary],
        series: [%{name: binary, sequence: binary | nil}],
        publisher: binary | nil,
        published_date: Date.t() | nil,
        isbn: binary | nil,
        asin: binary | nil,
        language: binary | nil,
        chapters: [%{title: binary | nil, start: float, end: float}]
      }
  """
  def read(path) do
    case read_result(path) do
      {:ok, metadata} ->
        metadata

      :missing ->
        nil

      {:error, reason} ->
        Logger.warning("Failed to parse sidecar #{path}: #{inspect(reason)}")
        nil
    end
  end

  def read_result(path) do
    with {:ok, content} <- File.read(path),
         {:ok, json} when is_map(json) <- Jason.decode(content) do
      {:ok, normalize(json)}
    else
      {:error, :enoent} -> :missing
      {:ok, _json} -> {:error, :invalid_sidecar}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @doc """
  Writes the book's portable metadata to an Audiobookshelf-style sidecar.

  Unknown fields in an existing sidecar are retained.
  """
  def write(path, book) do
    tmp_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with {:ok, existing} <- read_json(path),
         existing_metadata = existing["metadata"],
         existing_metadata = if(is_map(existing_metadata), do: existing_metadata, else: %{}),
         metadata = Map.merge(existing_metadata, metadata_json(book)),
         chapters = merge_chapters(existing["chapters"], book.chapters),
         json = existing |> Map.put("metadata", metadata) |> Map.put("chapters", chapters),
         {:ok, encoded} <- Jason.encode(json, pretty: true) do
      content = encoded <> "\n"

      if same_content?(path, content) do
        :ok
      else
        atomic_write(tmp_path, path, content)
      end
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  defp atomic_write(tmp_path, path, content) do
    with :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  defp same_content?(path, content) do
    case File.read(path) do
      {:ok, existing} -> existing == content
      {:error, _reason} -> false
    end
  end

  defp read_json(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, json} when is_map(json) -> {:ok, json}
          {:ok, _json} -> {:error, :invalid_sidecar}
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp metadata_json(book) do
    %{
      "title" => book.title,
      "subtitle" => book.subtitle,
      "description" => book.description,
      "authors" => Enum.map(book.authors, & &1.name),
      "narrators" => Enum.map(book.book_narrators, & &1.narrator.name),
      "series" => Enum.map(book.book_series, &series_json/1),
      "genres" => Enum.map(book.genres, & &1.name),
      "publisher" => book.publisher && book.publisher.name,
      "publishedDate" => book.published_date && Date.to_iso8601(book.published_date),
      "isbn" => book.isbn,
      "asin" => book.asin,
      "language" => book.language
    }
  end

  defp series_json(book_series) do
    %{"name" => book_series.series.name, "sequence" => book_series.sequence}
  end

  defp merge_chapters(existing, chapters) do
    existing = if is_list(existing), do: existing, else: []

    chapters
    |> Enum.map(fn chapter ->
      existing_chapter =
        Enum.find(existing, fn
          existing_chapter when is_map(existing_chapter) ->
            existing_chapter["start"] == chapter.start_seconds

          _other ->
            false
        end)

      existing_chapter = if is_map(existing_chapter), do: existing_chapter, else: %{}

      Map.merge(existing_chapter, %{
        "title" => chapter.title,
        "start" => chapter.start_seconds,
        "end" => chapter.end_seconds
      })
    end)
  end

  defp normalize(json) do
    # Audiobookshelf nests most fields under "metadata"; tolerate flat too.
    meta = Map.merge(json, Map.get(json, "metadata", %{}))

    %{
      present: present_fields(json, meta),
      title: string(meta["title"]),
      subtitle: string(meta["subtitle"]),
      description: string(meta["description"]),
      authors: names(meta["authors"] || meta["author"]),
      genres: genre_names(meta["genres"] || meta["genre"] || meta["tags"]),
      narrators: narrator_names(meta["narrators"] || meta["narrator"]),
      series: series(meta["series"]),
      publisher: string(meta["publisher"]),
      published_date:
        Pageless.Library.PublishedDate.parse(meta["publishedDate"] || meta["publishedYear"]),
      isbn: string(meta["isbn"]),
      asin: string(meta["asin"]),
      language: string(meta["language"]),
      chapters: chapters(json["chapters"] || meta["chapters"])
    }
  end

  defp present_fields(json, meta) do
    [
      {:title, ["title"]},
      {:subtitle, ["subtitle"]},
      {:description, ["description"]},
      {:authors, ["authors", "author"]},
      {:genres, ["genres", "genre", "tags"]},
      {:narrators, ["narrators", "narrator"]},
      {:series, ["series"]},
      {:publisher, ["publisher"]},
      {:published_date, ["publishedDate", "publishedYear"]},
      {:isbn, ["isbn"]},
      {:asin, ["asin"]},
      {:language, ["language"]}
    ]
    |> Enum.reduce(MapSet.new(), fn {field, keys}, present ->
      if Enum.any?(keys, &Map.has_key?(meta, &1)), do: MapSet.put(present, field), else: present
    end)
    |> then(fn present ->
      if Map.has_key?(json, "chapters") or Map.has_key?(meta, "chapters") do
        MapSet.put(present, :chapters)
      else
        present
      end
    end)
  end

  defp string(nil), do: nil
  defp string(s) when is_binary(s), do: ((s = String.trim(s)) != "" && s) || nil
  defp string(other), do: other |> to_string() |> string()

  # Accepts: nil | "A, B" | ["A", "B"] | [%{"name" => "A"}]
  defp names(nil), do: []
  defp names(list) when is_list(list), do: list |> Enum.map(&name_of/1) |> compact()

  defp names(str) when is_binary(str) do
    str |> String.split(",") |> Enum.map(&String.trim/1) |> compact()
  end

  defp name_of(%{"name" => name}), do: string(name)
  defp name_of(name) when is_binary(name), do: string(name)
  defp name_of(_), do: nil

  defp narrator_names(nil), do: []
  defp narrator_names(list) when is_list(list), do: names(list)
  defp narrator_names(name) when is_binary(name), do: [string(name)] |> compact()
  defp narrator_names(_), do: []

  defp genre_names(value) do
    value
    |> names()
    |> Enum.flat_map(fn genre ->
      genre
      |> String.split([",", ";", "/", ":"], trim: true)
      |> Enum.map(&String.trim/1)
    end)
    |> compact()
  end

  # Accepts: nil | "Name" | ["Name"] | [%{"name" => "...", "sequence" => "1"}]
  defp series(nil), do: []
  defp series(str) when is_binary(str), do: [%{name: string(str), sequence: nil}]

  defp series(list) when is_list(list),
    do: list |> Enum.map(&one_series/1) |> Enum.reject(&is_nil/1)

  defp one_series(%{"name" => name} = m),
    do:
      with(n when not is_nil(n) <- string(name), do: %{name: n, sequence: string(m["sequence"])})

  defp one_series(name) when is_binary(name) do
    with n when not is_nil(n) <- string(name), do: %{name: n, sequence: nil}
  end

  defp one_series(_), do: nil

  defp chapters(nil), do: []

  defp chapters(list) when is_list(list) do
    list
    |> Enum.map(fn ch ->
      %{
        title: string(ch["title"]),
        start: number(ch["start"]),
        end: number(ch["end"])
      }
    end)
    |> Enum.reject(&(&1.start == nil or &1.end == nil))
  end

  defp chapters(_), do: []

  defp number(nil), do: nil
  defp number(n) when is_number(n), do: n * 1.0

  defp number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp compact(list), do: list |> Enum.reject(&(is_nil(&1) or &1 == "")) |> Enum.uniq()
end
