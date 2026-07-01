defmodule Pageless.Format do
  @moduledoc """
  Layer-agnostic formatting helpers for durations and timestamps.

  These are pure functions with no dependency on the web or persistence
  layers, so they can be reused across the server, the web UI, and any
  other consumer of the domain (e.g. mirrored in a mobile client).
  """

  @doc """
  Formats a number of seconds as a human-friendly duration.

      iex> Pageless.Format.duration(0)
      "0m"
      iex> Pageless.Format.duration(95)
      "1m"
      iex> Pageless.Format.duration(3700)
      "1h 1m"
  """
  def duration(seconds) when is_number(seconds) do
    total = trunc(seconds)
    hours = div(total, 3600)
    minutes = div(rem(total, 3600), 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m"
      true -> "#{minutes}m"
    end
  end

  def duration(_), do: "0m"

  @doc """
  Formats a short duration with seconds precision, e.g. for chapter lengths.

      iex> Pageless.Format.short_duration(5)
      "5s"
      iex> Pageless.Format.short_duration(283)
      "4m 43s"
      iex> Pageless.Format.short_duration(3725)
      "1h 2m"
  """
  def short_duration(seconds) when is_number(seconds) do
    total = trunc(seconds)
    hours = div(total, 3600)
    minutes = div(rem(total, 3600), 60)
    secs = rem(total, 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m #{secs}s"
      true -> "#{secs}s"
    end
  end

  def short_duration(_), do: "0s"

  @doc """
  Formats seconds as a clock timestamp (H:MM:SS or M:SS).
  """
  def clock(seconds) when is_number(seconds) do
    total = trunc(seconds)
    hours = div(total, 3600)
    minutes = div(rem(total, 3600), 60)
    secs = rem(total, 60)

    if hours > 0 do
      "#{hours}:#{pad(minutes)}:#{pad(secs)}"
    else
      "#{minutes}:#{pad(secs)}"
    end
  end

  def clock(_), do: "0:00"

  @doc """
  Formats seconds as a zero-padded `HH:MM:SS` timestamp, used by editable
  time inputs.

      iex> Pageless.Format.hms(0)
      "00:00:00"
      iex> Pageless.Format.hms(3725)
      "01:02:05"
  """
  def hms(seconds) when is_number(seconds) do
    total = trunc(seconds)
    hours = div(total, 3600)
    minutes = div(rem(total, 3600), 60)
    secs = rem(total, 60)
    "#{pad(hours)}:#{pad(minutes)}:#{pad(secs)}"
  end

  def hms(_), do: "00:00:00"

  @doc """
  Parses an `HH:MM:SS`, `MM:SS`, or plain seconds string into a float number of
  seconds. Returns `nil` when the input can't be parsed.

      iex> Pageless.Format.parse_hms("01:02:05")
      3725.0
      iex> Pageless.Format.parse_hms("2:05")
      125.0
      iex> Pageless.Format.parse_hms("bad")
      nil
  """
  def parse_hms(string) when is_binary(string) do
    parts = string |> String.trim() |> String.split(":")

    with true <- parts != [] and Enum.all?(parts, &valid_int_part?/1),
         [h, m, s] <- pad_parts(parts) do
      (h * 3600 + m * 60 + s) * 1.0
    else
      _ -> nil
    end
  end

  def parse_hms(_), do: nil

  @doc """
  Formats a count with its noun, pluralizing the noun for any count other than
  1. Defaults to appending "s"; pass an explicit `plural` for irregular nouns.

      iex> Pageless.Format.count(1, "book")
      "1 book"
      iex> Pageless.Format.count(0, "book")
      "0 books"
      iex> Pageless.Format.count(3, "book")
      "3 books"
      iex> Pageless.Format.count(2, "series", "series")
      "2 series"
  """
  def count(n, singular, plural \\ nil) when is_integer(n) and is_binary(singular) do
    noun = if n == 1, do: singular, else: plural || singular <> "s"
    "#{n} #{noun}"
  end

  def date(nil, _format), do: ""
  def date(%DateTime{} = datetime, format), do: date(DateTime.to_date(datetime), format)

  def date(%Date{} = date, format) do
    case format do
      "MM/dd/yyyy" -> Calendar.strftime(date, "%m/%d/%Y")
      "dd/MM/yyyy" -> Calendar.strftime(date, "%d/%m/%Y")
      "dd.MM.yyyy" -> Calendar.strftime(date, "%d.%m.%Y")
      "yyyy-MM-dd" -> Calendar.strftime(date, "%Y-%m-%d")
      "MMM do, yyyy" -> "#{Calendar.strftime(date, "%b")} #{ordinal(date.day)}, #{date.year}"
      "MMMM do, yyyy" -> "#{Calendar.strftime(date, "%B")} #{ordinal(date.day)}, #{date.year}"
      "dd MMM yyyy" -> Calendar.strftime(date, "%d %b %Y")
      "dd MMMM yyyy" -> Calendar.strftime(date, "%d %B %Y")
      _other -> Calendar.strftime(date, "%d/%m/%Y")
    end
  end

  def time(value, format, opts \\ [])
  def time(nil, _format, _opts), do: ""

  def time(%DateTime{} = datetime, format, opts) do
    seconds? = Keyword.get(opts, :seconds, false)

    case {format, seconds?} do
      {"h:mma", false} -> Calendar.strftime(datetime, "%-I:%M%p")
      {"h:mma", true} -> Calendar.strftime(datetime, "%-I:%M:%S%p")
      {"HH:mm", true} -> Calendar.strftime(datetime, "%H:%M:%S")
      _other -> Calendar.strftime(datetime, "%H:%M")
    end
  end

  def datetime(value, date_format, time_format, opts \\ [])
  def datetime(nil, _date_format, _time_format, _opts), do: ""

  def datetime(%DateTime{} = datetime, date_format, time_format, opts) do
    "#{date(datetime, date_format)} #{time(datetime, time_format, opts)}"
  end

  defp valid_int_part?(part), do: part != "" and Regex.match?(~r/^\d+$/, part)

  defp pad_parts([s]), do: [0, 0, String.to_integer(s)]
  defp pad_parts([m, s]), do: [0, String.to_integer(m), String.to_integer(s)]

  defp pad_parts([h, m, s]),
    do: [String.to_integer(h), String.to_integer(m), String.to_integer(s)]

  defp pad_parts(_), do: :error

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"

  defp ordinal(day) when day in 11..13, do: "#{day}th"

  defp ordinal(day) do
    suffix = %{1 => "st", 2 => "nd", 3 => "rd"}[rem(day, 10)] || "th"
    "#{day}#{suffix}"
  end
end
