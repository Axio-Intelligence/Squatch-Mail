defmodule SquatchMail.Capture.Recorder do
  @moduledoc """
  Persists captured emails off the process that sent them.

  `SquatchMail.Capture`'s telemetry handler runs synchronously in the
  caller's process — the same process that just called
  `Mailer.deliver/2` — so it must return immediately. It hands each captured
  email's attrs to this GenServer with `GenServer.cast/2` (never `call/2`,
  which would block the caller waiting for a reply) and this process does
  the actual `SquatchMail.Tracker.record_email/1` write, off the caller.

  ## Backpressure

  Two independent limits bound the work this GenServer takes on, so a burst
  of sends can't turn into unbounded memory growth or a flooded database
  connection pool:

    * `SquatchMail.Config.max_queue/0` (default `10_000`) bounds how many
      captures may be *waiting* (queued in this process's own FIFO queue,
      not yet handed to a worker). Once the number of queued-plus-in-flight
      captures reaches this limit, new captures are dropped outright:
      `[:squatch_mail, :capture, :dropped]` fires and a warning logs — at
      most once a minute, so a sustained overload doesn't itself become a
      logging flood.
    * `SquatchMail.Config.max_concurrency/0` (default `50`) bounds how many
      captures are being persisted *at once*. Each in-flight persist checks
      out a connection from the host's `Repo` pool; without this cap, a
      burst large enough to exceed `:max_queue` would also be large enough
      to try to check out thousands of connections simultaneously and
      starve every other query the host app is running. Workers are
      unlinked (`Task.Supervisor.async_nolink/2`) so one crashing persist
      can't take this GenServer down with it.

  Queued work is drained into new workers as running ones finish, so the
  effective throughput is `:max_concurrency` persists in flight at any given
  moment, with up to `:max_queue` more waiting their turn.
  """

  use GenServer

  require Logger

  alias SquatchMail.{Config, Tracker}

  @log_throttle_ms 60_000

  defstruct queue: :queue.new(),
            in_flight: %{},
            dropped_since_log: 0,
            last_logged_at: nil

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
  accepted, queued, or dropped for being over capacity.
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
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    {:ok, %{state: %__MODULE__{}, task_supervisor: task_supervisor}}
  end

  @impl GenServer
  def handle_cast({:record, attrs}, %{state: state} = server_state) do
    total_outstanding = :queue.len(state.queue) + map_size(state.in_flight)

    if total_outstanding >= Config.max_queue() do
      {:noreply, %{server_state | state: note_dropped(state)}}
    else
      state = %{state | queue: :queue.in(attrs, state.queue)}
      {:noreply, %{server_state | state: drain(state, server_state.task_supervisor)}}
    end
  end

  @impl GenServer
  def handle_info({ref, _result}, %{state: state} = server_state) when is_reference(ref) do
    # The task completed normally; the DOWN message that follows is
    # demonitored so it isn't handled twice.
    Process.demonitor(ref, [:flush])
    state = %{state | in_flight: Map.delete(state.in_flight, ref)}
    {:noreply, %{server_state | state: drain(state, server_state.task_supervisor)}}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{state: state} = server_state) do
    # A worker crashed (persist/1 already rescues everything it can, but
    # this is the backstop for anything that still manages to escape, e.g.
    # an :exit signal). Its capture is lost, not requeued — retrying a
    # write that just crashed the process doing it isn't obviously safer
    # than dropping it, and requeuing indefinitely-failing attrs would be
    # its own way to never drain the queue.
    state = %{state | in_flight: Map.delete(state.in_flight, ref)}
    {:noreply, %{server_state | state: drain(state, server_state.task_supervisor)}}
  end

  # Starts new workers, up to `max_concurrency`, for whatever is queued.
  defp drain(state, task_supervisor) do
    if map_size(state.in_flight) >= Config.max_concurrency() do
      state
    else
      case :queue.out(state.queue) do
        {{:value, attrs}, queue} ->
          task = Task.Supervisor.async_nolink(task_supervisor, fn -> persist(attrs) end)
          state = %{state | queue: queue, in_flight: Map.put(state.in_flight, task.ref, true)}
          drain(state, task_supervisor)

        {:empty, _queue} ->
          state
      end
    end
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
