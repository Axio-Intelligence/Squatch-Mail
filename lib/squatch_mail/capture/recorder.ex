defmodule SquatchMail.Capture.Recorder do
  @moduledoc """
  Persists captured emails off the process that sent them.

  `SquatchMail.Capture`'s telemetry handler runs synchronously in the
  caller's process — the same process that just called
  `Mailer.deliver/2` — so it must return immediately. It hands each captured
  email's attrs to this GenServer with `GenServer.cast/2` (never `call/2`,
  which would block the caller waiting for a reply) and this process does
  the actual `SquatchMail.Tracker.record_email/1` write.

  ## Backpressure

  A burst of sends could otherwise queue unboundedly here while a slow
  database catches up. Instead, this GenServer tracks how many casts are
  currently pending processing and refuses new ones past
  `SquatchMail.Config.max_queue/0` (default `10_000`): the attrs are dropped,
  `[:squatch_mail, :capture, :dropped]` is emitted, and a warning is logged
  — but at most once a minute, so a sustained overload doesn't itself become
  a logging flood.
  """

  use GenServer

  require Logger

  alias SquatchMail.{Config, Tracker}

  @log_throttle_ms 60_000

  defstruct pending: 0, dropped_since_log: 0, last_logged_at: nil

  @doc """
  Starts the recorder. Only one is expected per application (registered
  under this module's name).
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueues an email's attrs for persistence.

  Non-blocking: returns immediately regardless of whether the attrs were
  accepted or dropped for being over capacity.
  """
  @spec record(map()) :: :ok
  def record(attrs) when is_map(attrs) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:record, attrs})
    end
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl GenServer
  def handle_cast({:record, attrs}, %__MODULE__{pending: pending} = state) do
    max_queue = Config.max_queue()

    if pending >= max_queue do
      {:noreply, note_dropped(state)}
    else
      pid = self()
      # Persist outside the GenServer loop so a slow Tracker write doesn't
      # block the next cast from being accepted — `pending` tracks
      # in-flight work regardless of which process is doing it.
      Task.start(fn ->
        persist(attrs)
        GenServer.cast(pid, :done)
      end)

      {:noreply, %{state | pending: pending + 1}}
    end
  end

  def handle_cast(:done, %__MODULE__{pending: pending} = state) do
    {:noreply, %{state | pending: max(pending - 1, 0)}}
  end

  defp persist(attrs) do
    case Tracker.record_email(attrs) do
      {:ok, _email} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "SquatchMail could not record a captured email: #{inspect(changeset.errors)}"
        )
    end
  rescue
    error ->
      Logger.error(
        "SquatchMail failed to persist a captured email: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )
  end

  defp note_dropped(%__MODULE__{dropped_since_log: dropped} = state) do
    :telemetry.execute([:squatch_mail, :capture, :dropped], %{count: 1}, %{})

    now = System.monotonic_time(:millisecond)

    if state.last_logged_at == nil or now - state.last_logged_at >= @log_throttle_ms do
      Logger.warning(
        "SquatchMail.Capture dropped #{dropped + 1} email(s) because its queue exceeded " <>
          "max_queue (#{Config.max_queue()}). Increase :max_queue or investigate why " <>
          "persistence is falling behind."
      )

      %{state | dropped_since_log: 0, last_logged_at: now}
    else
      %{state | dropped_since_log: dropped + 1}
    end
  end
end
