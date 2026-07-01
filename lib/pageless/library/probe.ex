defmodule Pageless.Library.Probe do
  @moduledoc """
  Thin wrapper around `ffprobe`/`ffmpeg` for extracting audio metadata,
  chapters and embedded cover art from media files.
  """

  require Logger

  @doc """
  Runs `ffprobe` on the given file and returns a normalized map:

      %{
        duration: float,
        codec: String.t() | nil,
        bitrate: integer | nil,
        tags: %{optional(String.t()) => String.t()},
        chapters: [%{title: String.t() | nil, start: float, end: float}]
      }

  Returns `{:ok, map}` or `{:error, reason}`.
  """
  def probe(path) do
    args = [
      "-v",
      "quiet",
      "-print_format",
      "json",
      "-show_format",
      "-show_streams",
      "-show_chapters",
      path
    ]

    case run_cmd(ffprobe_bin(), args) do
      {:ok, {output, 0}} ->
        with {:ok, json} <- Jason.decode(output) do
          {:ok, normalize(json)}
        end

      {:ok, {output, code}} ->
        Logger.warning("ffprobe failed (#{code}) for #{path}: #{output}")
        {:error, :ffprobe_failed}

      {:error, :enoent} ->
        Logger.error("ffprobe binary #{inspect(ffprobe_bin())} not found on PATH")
        {:error, :ffprobe_not_found}
    end
  end

  defp normalize(json) do
    format = Map.get(json, "format", %{})
    streams = Map.get(json, "streams", [])
    audio_stream = Enum.find(streams, &(&1["codec_type"] == "audio")) || %{}

    %{
      duration: parse_float(format["duration"] || audio_stream["duration"]),
      codec: audio_stream["codec_name"],
      bitrate: parse_int(format["bit_rate"] || audio_stream["bit_rate"]),
      tags: normalize_tags(format["tags"] || %{}),
      chapters: normalize_chapters(Map.get(json, "chapters", []))
    }
  end

  defp normalize_tags(tags) when is_map(tags) do
    Map.new(tags, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)
  end

  defp normalize_chapters(chapters) when is_list(chapters) do
    chapters
    |> Enum.map(fn ch ->
      %{
        title: get_in(ch, ["tags", "title"]),
        start: parse_float(ch["start_time"]),
        end: parse_float(ch["end_time"])
      }
    end)
    |> Enum.reject(&(&1.start == nil or &1.end == nil))
  end

  @doc """
  Extracts embedded cover art from `path` into `dest` using ffmpeg.

  Returns `:ok` if a cover was written, `{:error, reason}` otherwise.
  """
  def extract_cover(path, dest) do
    args = ["-v", "quiet", "-y", "-i", path, "-an", "-vcodec", "copy", dest]

    case run_cmd(ffmpeg_bin(), args) do
      {:ok, {_, 0}} ->
        if File.exists?(dest) and File.stat!(dest).size > 0 do
          :ok
        else
          {:error, :no_cover}
        end

      {:ok, {_output, _code}} ->
        {:error, :no_cover}

      {:error, :enoent} ->
        Logger.error("ffmpeg binary #{inspect(ffmpeg_bin())} not found on PATH")
        {:error, :ffmpeg_not_found}
    end
  end

  # Wraps `System.cmd/3` so a missing binary (`:enoent`) becomes an error tuple
  # instead of raising, allowing the scanner to degrade gracefully.
  defp run_cmd(bin, args) do
    {:ok, System.cmd(bin, args, stderr_to_stdout: true)}
  rescue
    e in ErlangError ->
      case e do
        %ErlangError{original: :enoent} -> {:error, :enoent}
        _ -> reraise(e, __STACKTRACE__)
      end
  end

  defp parse_float(nil), do: nil
  defp parse_float(n) when is_number(n), do: n * 1.0

  defp parse_float(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp ffprobe_bin, do: System.get_env("FFPROBE_BIN") || "ffprobe"
  defp ffmpeg_bin, do: System.get_env("FFMPEG_BIN") || "ffmpeg"
end
