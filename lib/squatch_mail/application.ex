defmodule SquatchMail.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Shared Finch pool used both for the SES v2 client (`aws` package)
      # and as Swoosh's API client, so we never need to add hackney.
      {Finch, name: SquatchMail.Finch},

      # Persists captured emails off the caller's process (see
      # SquatchMail.TelemetryCapture's moduledoc for why this must never
      # block or raise in the process that called Mailer.deliver/2).
      {Task.Supervisor, name: SquatchMail.TaskSupervisor}

      # TODO: start the retention/pruning worker here once suppression +
      # retention policies land.
    ]

    with {:ok, pid} <- Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__) do
      :ok = SquatchMail.TelemetryCapture.attach()
      {:ok, pid}
    end
  end
end
