defmodule SquatchMail.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Shared Finch pool used both for the SES v2 client (`aws` package)
      # and as Swoosh's API client, so we never need to add hackney.
      {Finch, name: SquatchMail.Finch}

      # TODO: attach the Swoosh telemetry capture handler here once the
      # capture engine lands (see FEATURES.md P1 "telemetry capture mode").
      # TODO: start the retention/pruning worker here once suppression +
      # retention policies land.
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
