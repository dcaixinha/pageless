defmodule Mix.Tasks.Pageless.ImportAudiobookshelf do
  @moduledoc """
  Imports one-time Audiobookshelf data into Pageless.

      mix pageless.import_audiobookshelf \
        --url http://localhost:13378 \
        --token "$ABS_TOKEN" \
        --user user@example.com \
        --path-map /audiobooks=/media/audiobooks \
        --dry-run

  `--path-map` maps an Audiobookshelf path prefix to the matching Pageless path
  prefix (`ABS_PREFIX=PAGELESS_PREFIX`). It may be given multiple times.

  By default all Audiobookshelf book libraries are scanned. Pass `--library` to
  restrict the import to specific libraries (matched by name, case-insensitive,
  or by id). It may be given multiple times:

      mix pageless.import_audiobookshelf \
        --url http://localhost:13378 \
        --token "$ABS_TOKEN" \
        --user user@example.com \
        --library "Audiobooks" \
        --dry-run

  By default metadata only fills blank Pageless fields. Covers are imported when
  Pageless has no cover. Listening history is imported only with
  `--include-history`.

  ## Production releases

  This Mix task is only available in development. In a production release (where
  Mix is not installed) run the equivalent, which accepts the same flags:

      bin/import_audiobookshelf --url ... --token ... --user ... --dry-run
  """

  use Mix.Task

  alias Pageless.Importers.Audiobookshelf.CLI

  @shortdoc "Imports Audiobookshelf data"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case CLI.main(args, fn line -> Mix.shell().info(line) end) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end
end
