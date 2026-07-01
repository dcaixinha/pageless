defmodule Pageless.Media do
  @moduledoc """
  Helpers for locating and managing media artifacts stored outside of
  `priv/static`.

  The base directory is configured via `config :pageless, :media_path` and may
  be overridden at runtime with the `PAGELESS_MEDIA_PATH` environment variable.

  Layout under the media path:

      <media_path>/
        covers/<book_id>.jpg   # extracted/derived cover art

  """

  @doc """
  Returns the configured base media directory as an absolute path.
  """
  def base_path do
    Application.fetch_env!(:pageless, :media_path)
  end

  @doc """
  Returns the directory where cover art is stored, ensuring it exists.
  """
  def covers_path do
    path = Path.join(base_path(), "covers")
    File.mkdir_p!(path)
    path
  end

  @doc """
  Returns the absolute path to a book's cover file for the given extension.
  """
  def cover_path(book_id, ext \\ "jpg") do
    Path.join(covers_path(), "#{book_id}.#{ext}")
  end

  @doc """
  Removes any existing cover files for a book (any extension).
  """
  def delete_covers(book_id) do
    covers_path()
    |> Path.join("#{book_id}.*")
    |> Path.wildcard()
    |> Enum.each(&File.rm/1)
  end

  @doc """
  Stores cover data for a book, replacing any existing cover.

  Returns the absolute path the cover was written to.
  """
  def store_cover(book_id, binary, ext) when is_binary(binary) do
    ext = normalize_ext(ext)
    delete_covers(book_id)
    dest = cover_path(book_id, ext)
    File.write!(dest, binary)
    dest
  end

  @doc """
  Copies a cover file from `src` into the media dir for a book, replacing any
  existing cover. Returns the destination path.
  """
  def copy_cover(book_id, src) do
    ext = src |> Path.extname() |> String.trim_leading(".") |> normalize_ext()
    delete_covers(book_id)
    dest = cover_path(book_id, ext)
    File.cp!(src, dest)
    dest
  end

  defp normalize_ext(ext) do
    case ext |> to_string() |> String.downcase() do
      e when e in ~w(jpg jpeg png webp) -> e
      _ -> "jpg"
    end
  end

  @doc """
  Ensures the base media directory (and standard subdirectories) exist.
  """
  def ensure_dirs! do
    File.mkdir_p!(base_path())
    File.mkdir_p!(covers_path())
    :ok
  end
end
