defmodule Pageless.Library.Chapters do
  @moduledoc """
  Pure, layer-agnostic helpers for reasoning about a book's chapters.

  These functions take plain chapter data (any struct/map exposing
  `start_seconds` and `end_seconds`) and a playback position, with no
  dependency on the web or persistence layers, so they can be reused across
  the server, the web UI, and mirrored in a mobile client.
  """

  @doc """
  Returns the zero-based index of the chapter that contains `position`
  (in seconds), or `nil` when there are no chapters.

  Chapters are expected to be contiguous and ordered. A position at or past
  the end of the last chapter resolves to the last chapter; a position before
  the first chapter resolves to the first chapter.

      iex> chapters = [
      ...>   %{start_seconds: 0.0, end_seconds: 500.0},
      ...>   %{start_seconds: 500.0, end_seconds: 1000.0}
      ...> ]
      iex> Pageless.Library.Chapters.current_index(chapters, 700.0)
      1
      iex> Pageless.Library.Chapters.current_index(chapters, 0.0)
      0
      iex> Pageless.Library.Chapters.current_index(chapters, 5000.0)
      1
      iex> Pageless.Library.Chapters.current_index([], 10.0)
      nil
  """
  def current_index([], _position), do: nil

  def current_index(chapters, position) do
    chapters
    |> Enum.find_index(fn ch ->
      position >= ch.start_seconds and position < ch.end_seconds
    end)
    |> case do
      nil -> if position >= List.last(chapters).end_seconds, do: length(chapters) - 1, else: 0
      idx -> idx
    end
  end
end
