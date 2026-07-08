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
      SquatchMail.TelemetryCapture.Recorder,

      # Periodically prunes emails/events/webhook_logs per retention_days
      # (see SquatchMail.Pruner's moduledoc). Runs on a timer regardless of
      # :enabled so it can be toggled at runtime without a restart; the
      # first prune waits a full interval rather than firing at boot.
      SquatchMail.Pruner
    ]

    with {:ok, pid} <- Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__) do
      :ok = SquatchMail.TelemetryCapture.attach()
      {:ok, pid}
    end
  end
end
