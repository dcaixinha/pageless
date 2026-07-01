defmodule Pageless.Release do
  @moduledoc """
  Tasks that can be run in production without Mix installed.

  Usage:

      bin/pageless eval "Pageless.Release.migrate()"
      bin/pageless eval "Pageless.Release.create_and_migrate()"

  The Audiobookshelf importer is also exposed here so it can be run from a
  release as `bin/import_audiobookshelf ...` via `rel/overlays/bin`.
  """

  @app :pageless

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def create_and_migrate do
    load_app()

    for repo <- repos() do
      case repo.__adapter__().storage_up(repo.config()) do
        :ok -> :ok
        {:error, :already_up} -> :ok
        {:error, term} -> raise "Could not create database: #{inspect(term)}"
      end

      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Runs the Audiobookshelf importer in a release.

  Accepts the same command-line arguments as the
  `mix pageless.import_audiobookshelf` task. Starts just the repo and HTTP
  client (not the web endpoint), prints the report and halts with a non-zero
  exit status on failure.
  """
  def import_audiobookshelf(argv) when is_list(argv) do
    load_app()

    # Start the HTTP client stack (Req/Finch) and the repo, but not the web
    # endpoint or the rest of the supervision tree: this is a one-off command
    # and starting the Endpoint would needlessly bind the HTTP port.
    {:ok, _} = Application.ensure_all_started(:req)

    result =
      Ecto.Migrator.with_repo(Pageless.Repo, fn _repo ->
        Pageless.Importers.Audiobookshelf.CLI.main(argv)
      end)

    case result do
      {:ok, :ok, _apps} ->
        :ok

      {:ok, {:error, message}, _apps} ->
        IO.puts(:stderr, message)
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "Failed to start repo: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
