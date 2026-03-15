defmodule LostGreen.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LostGreenWeb.Telemetry,
      LostGreen.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:lost_green, :ecto_repos), skip: skip_migrations?()},
      {DynamicSupervisor, strategy: :one_for_one, name: LostGreen.Metrics.Supervisor},
      {DNSCluster, query: Application.get_env(:lost_green, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: LostGreen.PubSub},
      # Start a worker by calling: LostGreen.Worker.start_link(arg)
      # {LostGreen.Worker, arg},
      # Start to serve requests, typically the last entry
      LostGreenWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LostGreen.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LostGreenWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations? do
    # Run migrations in a release or when launched by Tauri.
    System.get_env("RELEASE_NAME") == nil and System.get_env("RUNNING_UNDER_TAURI") == nil
  end
end
