defmodule Pageless.Importers.Audiobookshelf.CLI do
  @moduledoc """
  Shared, Mix-free command-line frontend for the Audiobookshelf importer.

  This module contains all argument parsing and report formatting so the exact
  same behavior is available both from the `mix pageless.import_audiobookshelf`
  task (development) and from a production release via
  `Pageless.Release.import_audiobookshelf/1` (which has no access to Mix).
  """

  alias Pageless.Importers.Audiobookshelf

  @switches [
    url: :string,
    token: :string,
    user: :string,
    path_map: :keep,
    library: :keep,
    dry_run: :boolean,
    import_covers: :boolean,
    include_history: :boolean
  ]

  @doc """
  Parses `argv`, runs the importer and prints a report.

  `output` is a 1-arity function used to emit each line (defaults to
  `IO.puts/1`). Returns `:ok` on success or `{:error, message}` on failure,
  where `message` is a human-readable string ready to print.
  """
  def main(argv, output \\ &IO.puts/1) when is_list(argv) and is_function(output, 1) do
    with {:ok, opts} <- parse_args(argv),
         {:ok, report} <- run(opts) do
      report |> format_report() |> Enum.each(output)
      :ok
    end
  end

  @doc """
  Parses the raw `argv` into the keyword options expected by
  `Pageless.Importers.Audiobookshelf.run/1`.

  Returns `{:ok, opts}` or `{:error, message}`.
  """
  def parse_args(argv) do
    {opts, _argv, invalid} = OptionParser.parse(argv, strict: @switches)

    cond do
      invalid != [] ->
        {:error, "Invalid options: #{inspect(invalid)}"}

      true ->
        with {:ok, path_maps} <- parse_path_maps(Keyword.get_values(opts, :path_map)) do
          opts =
            opts
            |> Keyword.put(:path_maps, path_maps)
            |> Keyword.put(:libraries, Keyword.get_values(opts, :library))
            |> Keyword.put_new(:import_covers, true)

          {:ok, opts}
        end
    end
  end

  defp run(opts) do
    case Audiobookshelf.run(opts) do
      {:ok, report} ->
        {:ok, report}

      {:error, {:unknown_libraries, names}} ->
        {:error, "No Audiobookshelf library matched: #{Enum.join(names, ", ")}"}

      {:error, reason} ->
        {:error, "Audiobookshelf import failed: #{inspect(reason)}"}
    end
  end

  defp parse_path_maps(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case String.split(value, "=", parts: 2) do
        [from, to] when from != "" and to != "" ->
          {:cont, {:ok, [{from, to} | acc]}}

        _ ->
          {:halt, {:error, "Invalid --path-map #{inspect(value)}. Expected FROM=TO"}}
      end
    end)
    |> case do
      {:ok, maps} -> {:ok, Enum.reverse(maps)}
      error -> error
    end
  end

  @doc """
  Formats a report map (as returned by the importer) into a list of printable
  lines.
  """
  def format_report(report) do
    header = [
      "Audiobookshelf import #{if report.dry_run, do: "dry run", else: "complete"}",
      "ABS libraries: #{report.totals.abs_libraries}",
      "ABS items: #{report.totals.abs_items}",
      "ABS collections: #{report.totals.abs_collections}",
      "ABS playlists: #{report.totals.abs_playlists}",
      "Matched: #{report.totals.matched}",
      "Unmatched: #{report.totals.unmatched}",
      "Ambiguous: #{report.totals.ambiguous}"
    ]

    imported =
      unless report.dry_run do
        [
          "Metadata updates: #{report.imported.metadata}",
          "Covers imported: #{report.imported.covers}",
          "Progress rows imported: #{report.imported.progress}",
          "Bookmarks imported: #{report.imported.bookmarks}",
          "Collections imported: #{report.imported.collections}",
          "Playlists imported: #{report.imported.playlists}",
          "History sessions imported: #{report.imported.history}"
        ]
      end

    unmatched =
      unless report.unmatched == [] do
        ["", "Unmatched items:"] ++
          Enum.map(report.unmatched, &"  #{&1.title || &1.id}: #{&1.path}")
      end

    ambiguous =
      unless report.ambiguous == [] do
        ["", "Ambiguous items:"] ++
          Enum.map(report.ambiguous, &"  #{&1.item.title || &1.item.id}: #{&1.item.path}")
      end

    [header, imported, unmatched, ambiguous]
    |> Enum.reject(&is_nil/1)
    |> Enum.concat()
  end
end
