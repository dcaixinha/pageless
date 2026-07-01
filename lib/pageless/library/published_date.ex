defmodule Pageless.Library.PublishedDate do
  @moduledoc """
  Parses the loosely-typed "published date" values that come from sidecar
  metadata and Audiobookshelf into a `Date`.

  Audiobookshelf (and embedded tags) may provide a full date (`"2014-11-25"`),
  a year+month (`"2015-04"`), or just a year (`"2021"`). Partial values are
  coerced to a full `Date` by defaulting the missing month/day to January 1st,
  so the value can be stored in a `:date` column without failing.
  """

  @doc """
  Parses `value` into a `Date`, or returns `nil` when it cannot be interpreted.

      iex> Pageless.Library.PublishedDate.parse("2014-11-25")
      ~D[2014-11-25]

      iex> Pageless.Library.PublishedDate.parse("2015-04")
      ~D[2015-04-01]

      iex> Pageless.Library.PublishedDate.parse("2021")
      ~D[2021-01-01]

      iex> Pageless.Library.PublishedDate.parse(2021)
      ~D[2021-01-01]

      iex> Pageless.Library.PublishedDate.parse("nonsense")
      nil
  """
  def parse(nil), do: nil
  def parse(%Date{} = date), do: date

  def parse(value) when is_integer(value) do
    build(value, 1, 1)
  end

  def parse(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        nil

      trimmed ->
        # Take the leading date-ish portion (handles full ISO-8601 timestamps too).
        trimmed
        |> String.split(["T", " "], parts: 2)
        |> List.first()
        |> parse_parts()
    end
  end

  def parse(_), do: nil

  defp parse_parts(str) do
    case String.split(str, "-", parts: 3) do
      [y] -> from_ints(y, "1", "1")
      [y, m] -> from_ints(y, m, "1")
      [y, m, d] -> from_ints(y, m, d)
    end
  end

  defp from_ints(y, m, d) do
    with {year, ""} <- Integer.parse(y),
         {month, ""} <- Integer.parse(m),
         {day, ""} <- Integer.parse(d) do
      build(year, month, day)
    else
      _ -> nil
    end
  end

  defp build(year, month, day) do
    case Date.new(year, month, day) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end
end
