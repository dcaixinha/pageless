defmodule Pageless.LibraryFixtures do
  @moduledoc """
  Test helpers for creating entities via the `Pageless.Library` context.
  """

  alias Pageless.Library
  alias Pageless.Repo
  alias Pageless.Library.{Book, Chapter, AudioFile}

  def library_fixture(attrs \\ %{}) do
    {:ok, library} =
      attrs
      |> Enum.into(%{name: "Library #{System.unique_integer([:positive])}", media_type: "book"})
      |> Library.create_library()

    library
  end

  def book_fixture(attrs \\ %{}) do
    library = attrs[:library] || library_fixture()
    n = System.unique_integer([:positive])

    book =
      %Book{library_id: library.id}
      |> Book.changeset(
        Enum.into(attrs, %{
          title: "Book #{n}",
          folder_path: "/books/book_#{n}",
          duration_seconds: 3600.0
        })
      )
      |> Repo.insert!()

    book
  end

  def audio_file_fixture(book, attrs \\ %{}) do
    %AudioFile{book_id: book.id}
    |> AudioFile.changeset(
      Enum.into(attrs, %{
        path: "#{book.folder_path}/audio.m4b",
        index: 0,
        duration_seconds: book.duration_seconds,
        codec: "aac",
        mime_type: "audio/mp4"
      })
    )
    |> Repo.insert!()
  end

  def chapter_fixture(book, attrs \\ %{}) do
    %Chapter{book_id: book.id}
    |> Chapter.changeset(
      Enum.into(attrs, %{title: "Chapter 1", start_seconds: 0.0, end_seconds: 600.0, index: 0})
    )
    |> Repo.insert!()
  end
end
