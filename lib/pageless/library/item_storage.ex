defmodule Pageless.Library.ItemStorage do
  @moduledoc false

  require Logger
  import Ecto.Query

  alias Pageless.Library, as: LibraryContext
  alias Pageless.Library.{Book, Library, Sidecar}
  alias Pageless.Media
  alias Pageless.Repo

  @cover_extensions ~w(jpg jpeg png webp)

  def copy_cover(%Book{} = book, src) do
    library = library_for(book)

    if library.store_covers_with_item do
      ext = extension(src)

      if Path.dirname(Path.expand(src)) == Path.expand(book.folder_path) do
        delete_item_covers(book, src)
        Media.delete_covers(book.id)
        {:ok, src}
      else
        with_item_cover_fallback(
          book,
          fn -> atomic_item_cover(book, ext, &File.cp(src, &1)) end,
          fn -> Media.copy_cover(book.id, src) end
        )
      end
    else
      dest = Media.copy_cover(book.id, src)
      {:ok, dest}
    end
  end

  def store_cover(%Book{} = book, binary, ext) when is_binary(binary) do
    library = library_for(book)
    ext = normalize_ext(ext)

    if library.store_covers_with_item do
      with_item_cover_fallback(
        book,
        fn -> atomic_item_cover(book, ext, &File.write(&1, binary)) end,
        fn -> Media.store_cover(book.id, binary, ext) end
      )
    else
      dest = Media.store_cover(book.id, binary, ext)
      {:ok, dest}
    end
  end

  def sync_metadata(%Book{} = book, opts \\ []) do
    if library_for(book).store_metadata_with_item do
      book = LibraryContext.get_book!(book.id)
      path = Path.join(book.folder_path, "metadata.json")
      generated? = Keyword.get(opts, :generated, false)

      result =
        if (generated? and book.generated_metadata_hash) &&
             book.generated_metadata_hash != file_hash(path) do
          :external_change
        else
          Sidecar.write(path, book)
        end

      case result do
        :ok ->
          generated_hash = if generated?, do: file_hash(path)

          Book
          |> where([b], b.id == ^book.id)
          |> Repo.update_all(set: [generated_metadata_hash: generated_hash])

          :ok

        :external_change ->
          Book
          |> where([b], b.id == ^book.id)
          |> Repo.update_all(set: [generated_metadata_hash: nil])

          :ok

        {:error, reason} ->
          warn_item_write(book, "metadata", reason)
          {:warning, reason}
      end
    else
      :ok
    end
  end

  defp atomic_item_cover(book, ext, writer) do
    dest = item_cover_path(book, ext)
    tmp_path = "#{dest}.tmp-#{System.unique_integer([:positive])}"

    case writer.(tmp_path) do
      :ok ->
        result =
          if same_file?(tmp_path, dest) do
            File.rm(tmp_path)
            :ok
          else
            File.rename(tmp_path, dest)
          end

        case result do
          :ok ->
            delete_item_covers(book, dest)
            {:ok, dest}

          {:error, reason} ->
            File.rm(tmp_path)
            {:error, reason}
        end

      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  defp same_file?(left, right) do
    with {:ok, left_stat} <- File.stat(left),
         {:ok, right_stat} <- File.stat(right),
         true <- left_stat.size == right_stat.size,
         {:ok, left_content} <- File.read(left),
         {:ok, right_content} <- File.read(right) do
      left_content == right_content
    else
      _ -> false
    end
  end

  def file_hash(path) do
    case File.read(path) do
      {:ok, content} -> :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      {:error, _reason} -> nil
    end
  end

  defp with_item_cover_fallback(book, item_writer, central_writer) do
    case item_writer.() do
      {:ok, path} ->
        Media.delete_covers(book.id)
        {:ok, path}

      {:error, reason} ->
        warn_item_write(book, "cover", reason)
        {:ok, central_writer.()}
    end
  end

  defp delete_item_covers(book, except) do
    @cover_extensions
    |> Enum.map(&item_cover_path(book, &1))
    |> Enum.reject(&(&1 == except))
    |> Enum.each(&File.rm/1)
  end

  defp item_cover_path(book, ext), do: Path.join(book.folder_path, "cover.#{normalize_ext(ext)}")

  defp library_for(%Book{library: %Library{} = library}), do: library
  defp library_for(%Book{library_id: library_id}), do: Repo.get!(Library, library_id)

  defp extension(path), do: path |> Path.extname() |> String.trim_leading(".") |> normalize_ext()

  defp normalize_ext(ext) do
    case ext |> to_string() |> String.downcase() do
      ext when ext in @cover_extensions -> ext
      _ -> "jpg"
    end
  end

  defp warn_item_write(book, artifact, reason) do
    Logger.warning(
      "Failed to store #{artifact} with book #{book.id} in #{book.folder_path}: #{inspect(reason)}"
    )
  end
end
