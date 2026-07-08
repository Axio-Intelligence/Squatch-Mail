defmodule SquatchMail.Web.Live.TrailLog do
  @moduledoc """
  The Trail Log — SquatchMail's default landing page (`squatch_mail_dashboard`
  mounted at `/`), showing the live activity feed: stat strip, filters, and
  the sent-email activity table.

  ## Filters live in the URL

  Every filter (status, search, date range) is a query param, patched via
  `push_patch/2` from `handle_event/3` and re-read in `handle_params/3` — the
  same pattern `SquatchMail.Web.Live.Suppressions` uses. This is what lets
  `SquatchMail.Web.ActivityExportController`'s CSV export and the "back to
  Trail Log" link from the Sighting inspector both reconstruct the exact
  filter set a user was looking at, just from the URL.

  ## Live updates

  Rather than push every new email/event straight into the assigns from a
  telemetry handler (telemetry handlers run in the *emitting* process, not
  this LiveView's — attaching a handler here would execute in the wrong
  process and race with everything else), `mount/3` attaches a handler that
  simply forwards `[:squatch_mail, :email, :recorded]` telemetry events to
  this LiveView's own process via `send/2`, debounced so a burst of events
  collapses into a single reload. A 30s poll (`:timer.send_interval/2`) is
  the fallback for whatever telemetry might miss (host restarts the handler
  attachment, a handler exception detaches it, etc.) The handler is detached
  in `terminate/2` — leaving it attached would leak a reference to a dead
  LiveView process on every mount.
  """

  use Phoenix.LiveView

  alias SquatchMail.Tracker
  alias SquatchMail.Web.{Components, Layouts}

  @page_size 50
  @refresh_debounce_ms 500
  @poll_interval_ms 30_000

  @statuses SquatchMail.Email.statuses()

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, :refresh_scheduled?, false)

    socket =
      if connected?(socket) do
        :timer.send_interval(@poll_interval_ms, self(), :poll_refresh)
        assign(socket, :telemetry_handler_id, attach_telemetry())
      else
        assign(socket, :telemetry_handler_id, nil)
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = filters_from_params(params)

    socket =
      socket
      |> assign(:filters, filters)
      |> assign(:raw_params, params)
      |> assign(:page_size, @page_size)
      |> assign(:offset, 0)
      |> load_emails(replace?: true)
      |> load_stats()

    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if handler_id = socket.assigns[:telemetry_handler_id] do
      :telemetry.detach(handler_id)
    end

    :ok
  end

  ## ---- Events ----------------------------------------------------------------

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply, push_patch(socket, to: patch_path(socket, %{status: status}))}
  end

  def handle_event("filter_range", %{"range" => range}, socket) do
    {:noreply, push_patch(socket, to: patch_path(socket, %{range: range}))}
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: patch_path(socket, %{q: q}))}
  end

  def handle_event("load_more", _params, socket) do
    socket =
      socket
      |> update(:offset, &(&1 + @page_size))
      |> load_emails(replace?: false)

    {:noreply, socket}
  end

  def handle_event("open_sighting", %{"public_id" => public_id}, socket) do
    # push_navigate/2, not push_patch/2: the Sighting inspector is a
    # different LiveView module, and push_patch only works within the same
    # mounted LiveView.
    {:noreply, push_navigate(socket, to: sighting_path(socket, public_id))}
  end

  ## ---- Telemetry-driven + polled refresh --------------------------------------

  @impl true
  def handle_info({:squatch_mail_activity, :refresh}, socket) do
    if socket.assigns.refresh_scheduled? do
      {:noreply, socket}
    else
      Process.send_after(self(), :do_refresh, @refresh_debounce_ms)
      {:noreply, assign(socket, :refresh_scheduled?, true)}
    end
  end

  def handle_info(:do_refresh, socket) do
    socket =
      socket
      |> assign(:refresh_scheduled?, false)
      |> assign(:offset, 0)
      |> load_emails(replace?: true)
      |> load_stats()

    {:noreply, socket}
  end

  def handle_info(:poll_refresh, socket) do
    handle_info(:do_refresh, socket)
  end

  defp attach_telemetry do
    handler_id = "squatch-mail-trail-log-#{inspect(self())}"
    liveview_pid = self()

    :telemetry.attach(
      handler_id,
      [:squatch_mail, :email, :recorded],
      fn _event, _measurements, _metadata, _config ->
        send(liveview_pid, {:squatch_mail_activity, :refresh})
      end,
      nil
    )

    handler_id
  end

  ## ---- Data loading ------------------------------------------------------------

  defp load_emails(socket, opts) do
    replace? = Keyword.fetch!(opts, :replace?)
    filters = socket.assigns.filters

    # The date bounds in `filters` are frozen at whatever moment
    # `handle_params/3` last ran (e.g. a page load or a filter change) — reused
    # as-is here, a telemetry-driven or polled refresh's `to_date` would
    # already be in the past by the time new activity arrives, silently
    # excluding it. Recompute fresh bounds on every load instead (same as
    # `load_stats/1` already does via `stats_range/1`), so "now" always means
    # now.
    {from_dt, to_dt} = date_bounds(filters)

    query_filters =
      filters
      |> Map.take([:status, :search])
      |> Map.put(:from_date, from_dt)
      |> Map.put(:to_date, to_dt)
      |> Map.put(:limit, socket.assigns.page_size)
      |> Map.put(:offset, socket.assigns.offset)

    new_emails = Tracker.list_emails(query_filters)

    emails =
      if replace?, do: new_emails, else: socket.assigns.emails ++ new_emails

    engagement = Tracker.engagement_counts(Enum.map(emails, & &1.id))

    socket
    |> assign(:emails, emails)
    |> assign(:engagement, engagement)
    |> assign(:has_more?, length(new_emails) == socket.assigns.page_size)
  end

  defp date_bounds(%{range: "all"}), do: {nil, nil}
  defp date_bounds(filters), do: stats_range(filters)

  defp load_stats(socket) do
    {from_dt, to_dt} = stats_range(socket.assigns.filters)
    assign(socket, :stats, Tracker.stats(%{from: from_dt, to: to_dt}))
  end

  defp stats_range(filters) do
    to_dt = DateTime.utc_now()

    from_dt =
      case Map.get(filters, :range, "7d") do
        "24h" -> DateTime.add(to_dt, -1, :day)
        "7d" -> DateTime.add(to_dt, -7, :day)
        "30d" -> DateTime.add(to_dt, -30, :day)
        "all" -> DateTime.add(to_dt, -3650, :day)
        _ -> DateTime.add(to_dt, -7, :day)
      end

    {from_dt, to_dt}
  end

  ## ---- Filters (URL params <-> Tracker filters) --------------------------------

  @doc """
  Builds `Tracker.list_emails/1`-shaped filters from Trail Log's query
  params. Public and shared with `SquatchMail.Web.ActivityExportController`
  so the CSV export always matches whatever's on screen.
  """
  @spec filters_from_params(map()) :: map()
  def filters_from_params(params) do
    %{}
    |> put_present(:status, normalize_status(params["status"]))
    |> put_present(:search, normalize_search(params["q"]))
    |> Map.put(:range, normalize_range(params["range"]))
    |> put_date_bounds(params["range"])
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp normalize_status(status) when status in @statuses, do: status
  defp normalize_status(_), do: nil

  defp normalize_search(nil), do: nil

  defp normalize_search(q) do
    case String.trim(q) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @valid_ranges ~w(24h 7d 30d all)
  defp normalize_range(range) when range in @valid_ranges, do: range
  defp normalize_range(_), do: "7d"

  defp put_date_bounds(filters, range) do
    case normalize_range(range) do
      "all" ->
        filters

      normalized ->
        {from_dt, to_dt} = stats_range(%{range: normalized})
        filters |> Map.put(:from_date, from_dt) |> Map.put(:to_date, to_dt)
    end
  end

  defp patch_path(socket, changes) do
    params =
      socket.assigns.raw_params
      |> Map.take(["status", "q", "range"])
      |> Map.merge(Map.new(changes, fn {k, v} -> {to_string(k), v} end))
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    base = socket.assigns.dashboard_path

    case params do
      empty when map_size(empty) == 0 -> base
      params -> base <> "?" <> URI.encode_query(params)
    end
  end

  defp sighting_path(socket, public_id) do
    base = socket.assigns.dashboard_path <> "/sightings/" <> public_id

    case socket.assigns.raw_params do
      empty when map_size(empty) == 0 ->
        base

      params ->
        back = "?" <> URI.encode_query(params)
        base <> "?" <> URI.encode_query(%{"back" => back})
    end
  end

  ## ---- Rendering ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      page_title="Trail Log"
      active_nav={:trail_log}
      dashboard_path={@dashboard_path}
      flash={@flash}
    >
      <:actions>
        <Components.live_indicator />
        <a
          class="sq-btn sq-btn--ghost"
          href={@dashboard_path <> "/activity/export.csv?" <> URI.encode_query(@raw_params)}
        >
          Export CSV
        </a>
      </:actions>

      <.stat_strip stats={@stats} />

      <div class="sq-filter-bar">
        <form id="sq-trail-log-search" phx-change="search" phx-submit="search">
          <input
            type="text"
            class="sq-input"
            name="q"
            value={@filters[:search]}
            placeholder="Search subject, sender, recipient…"
            aria-label="Search"
            phx-debounce="250"
          />
        </form>

        <form id="sq-trail-log-status" phx-change="filter_status" phx-submit="filter_status">
          <select class="sq-select" name="status" aria-label="Filter by status">
            <option value="" selected={@filters[:status] == nil}>All statuses</option>
            <option :for={status <- status_options()} value={status} selected={@filters[:status] == status}>
              <%= String.capitalize(status) %>
            </option>
          </select>
        </form>

        <form id="sq-trail-log-range" phx-change="filter_range" phx-submit="filter_range">
          <select class="sq-select" name="range" aria-label="Date range">
            <option :for={{value, label} <- range_options()} value={value} selected={@filters.range == value}>
              <%= label %>
            </option>
          </select>
        </form>

        <span class="sq-filter-bar__spacer"></span>
      </div>

      <%= if @emails == [] do %>
        <Components.empty_state
          title="No sightings yet. The forest is quiet… too quiet."
          copy="Once your app sends its first email, its tracks will show up here in real time."
        />
      <% else %>
        <div class="sq-table-container">
          <table class="sq-table">
            <thead>
              <tr>
                <th>Recipient</th>
                <th>Status</th>
                <th>Engagement</th>
                <th>Sent</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={email <- @emails} phx-click="open_sighting" phx-value-public_id={email.public_id}>
                <td>
                  <div class="sq-table__recipient">
                    <span class="sq-table__recipient-email"><%= recipient_summary(email) %></span>
                    <span class="sq-table__recipient-subject"><%= email.subject %></span>
                  </div>
                </td>
                <td><Components.status_badge status={email.status} /></td>
                <td>
                  <.engagement_counts email={email} engagement={@engagement} /></td>
                <td class="sq-table__timestamp"><%= relative_time(email.sent_at || email.inserted_at) %></td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@has_more?} style="display: flex; justify-content: center; margin-top: 16px;">
          <button type="button" class="sq-btn sq-btn--ghost" phx-click="load_more">
            Load more
          </button>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  attr :email, :map, required: true
  attr :engagement, :map, required: true

  defp engagement_counts(assigns) do
    counts = Map.get(assigns.engagement, assigns.email.id, %{opens: 0, clicks: 0})
    assigns = assign(assigns, :counts, counts)

    ~H"""
    <span class="sq-table__engagement">
      <span :if={@counts.opens > 0}>◉ <%= @counts.opens %></span>
      <span :if={@counts.clicks > 0}>↗ <%= @counts.clicks %></span>
      <span :if={@counts.opens == 0 and @counts.clicks == 0}>—</span>
    </span>
    """
  end

  attr :stats, :map, required: true

  defp stat_strip(assigns) do
    ~H"""
    <Components.stat_strip
      sightings={Integer.to_string(@stats.current.total)}
      delivery_rate={"#{@stats.rates.delivered}%"}
      open_rate={"#{@stats.rates.opened}%"}
      click_rate={"#{@stats.rates.clicked}%"}
      bounce_rate={"#{@stats.rates.bounced}%"}
    />
    """
  end

  defp status_options, do: @statuses

  defp range_options do
    [
      {"24h", "Last 24 hours"},
      {"7d", "Last 7 days"},
      {"30d", "Last 30 days"},
      {"all", "All time"}
    ]
  end

  defp recipient_summary(%{recipients: []}), do: "(no recipients)"

  defp recipient_summary(%{recipients: [first | rest]}) do
    case rest do
      [] -> first.address
      more -> "#{first.address} +#{length(more)}"
    end
  end

  defp relative_time(nil), do: "—"

  defp relative_time(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end
end
