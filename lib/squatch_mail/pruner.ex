defmodule SquatchMail.Pruner do
  @moduledoc """
  Periodically prunes data older than the configured retention window.

  Calls `SquatchMail.Tracker.prune/0` (which itself reads `retention_days`
  off the source row, and applies a fixed 30-day window to `webhook_logs`)
  on a timer, every `SquatchMail.Config.pruner_interval_ms/0` (6 hours by
  default). The first run is delayed by a full interval rather than firing
  at boot, so a freshly-started host isn't immediately hit with a prune
  sweep before it's had a chance to configure anything. Call `run_now/0` to
  prune immediately (tests, a manual "prune now" admin action, etc).

  Disabled entirely (no timer scheduled) when
  `SquatchMail.Config.pruner_enabled?/0` is `false`.

  Failures are caught and logged rather than crashing the process — a
  transient database hiccup during one scheduled prune shouldn't take down
  the pruner and stop all future runs.

  Emits `[:squatch_mail, :prune, :done]` telemetry with measurements
  `%{emails: n, webhook_logs: n}` (plus `events` in metadata) after every
  run, scheduled or manual.
  """

  use GenServer

  require Logger

  alias SquatchMail.{Config, Tracker}

  @doc """
  Starts the pruner.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Runs a prune immediately, outside the regular schedule.

  Returns the same shape as `SquatchMail.Tracker.prune/0` and still emits
  `[:squatch_mail, :prune, :done]`.
  """
  @spec run_now() :: %{
          emails: non_neg_integer(),
          events: non_neg_integer(),
          webhook_logs: non_neg_integer()
        }
  def run_now do
    GenServer.call(__MODULE__, :run_now)
  end

  @impl GenServer
  def init(_opts) do
    if Config.pruner_enabled?() do
      schedule_next()
    end

    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:prune, state) do
    run_prune()

    if Config.pruner_enabled?() do
      schedule_next()
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:run_now, _from, state) do
    {:reply, run_prune(), state}
  end

  defp schedule_next do
    Process.send_after(self(), :prune, Config.pruner_interval_ms())
  end

  defp run_prune do
    result = Tracker.prune()

    :telemetry.execute(
      [:squatch_mail, :prune, :done],
      %{emails: result.emails, webhook_logs: result.webhook_logs},
      %{events: result.events}
    )

    Logger.info(
      "SquatchMail.Pruner pruned #{result.emails} email(s), #{result.events} orphan event(s), " <>
        "#{result.webhook_logs} webhook log(s)"
    )

    result
  rescue
    error ->
      Logger.error(
        "SquatchMail.Pruner failed to prune: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      %{emails: 0, events: 0, webhook_logs: 0}
  end
end
