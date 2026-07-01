defmodule Pageless.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Pageless.Media.ensure_dirs!()

    children = [
      PagelessWeb.Telemetry,
      Pageless.Repo,
      {DNSCluster, query: Application.get_env(:pageless, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Pageless.PubSub},
      {Registry, keys: :unique, name: Pageless.Library.WatcherRegistry},
      {Task.Supervisor, name: Pageless.HTTPTaskSupervisor},
      {Task.Supervisor, name: Pageless.ScannerSupervisor},
      Pageless.Library.WatcherSupervisor,
      Pageless.Library.ScanCoordinator,
      # Start to serve requests, typically the last entry
      PagelessWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Pageless.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PagelessWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
