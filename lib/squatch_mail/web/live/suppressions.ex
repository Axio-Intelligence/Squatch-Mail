defmodule SquatchMail.Web.Live.Suppressions do
  @moduledoc """
  The Do-Not-Disturb registry — `GET <dashboard_path>/suppressions`.

  Lists `SquatchMail.Suppression` rows (bounces, complaints, and manual
  entries), lets an operator add a manual suppression, remove any row, and
  release expired soft bounces in bulk.

  ## Reason filter via query params

  `handle_params/3` reads a `?reason=` query param (`hard_bounce`,
  `soft_bounce`, `complaint`, or `manual`) and pre-applies it as the reason
  filter, so links can deep-link into a single category. Note this filters
  *suppressions* — the sidebar's dedicated Bounces/Complaints pages
  (`/bounces`, `/complaints`, served by `SquatchMail.Web.Live.TrailLog`) list
  the bounced/complained *emails* instead.
  """

  use Phoenix.LiveView

  alias SquatchMail.Suppression
  alias SquatchMail.Tracker
  alias SquatchMail.Web.{Components, Layouts}

  @valid_reasons Suppression.reasons()

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:reason_filter, nil)
      |> assign(:address_query, "")
      |> assign(:add_error, nil)
      |> load_suppressions()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    reason = normalize_reason(params["reason"])
    address_query = params["q"] || ""

    socket =
      socket
      |> assign(:reason_filter, reason)
      |> assign(:address_query, address_query)
      |> load_suppressions()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_reason", %{"reason" => reason}, socket) do
    {:noreply,
     push_patch(socket,
       to: patch_path(socket, normalize_reason(reason), socket.assigns.address_query)
     )}
  end

  def handle_event("search_address", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: patch_path(socket, socket.assigns.reason_filter, q))}
  end

  def handle_event("add_suppression", %{"address" => address} = params, socket) do
    address = String.trim(address || "")
    notes = params["notes"]

    if address == "" do
      {:noreply, assign(socket, :add_error, "Give us an address to hush.")}
    else
      case Tracker.suppress(%{address: address, reason: "manual", notes: notes}) do
        {:ok, _suppression} ->
          {:noreply,
           socket
           |> assign(:add_error, nil)
           |> put_flash(:info, "#{address} added to the registry. The Squatch will steer clear.")
           |> load_suppressions()}

        {:error, changeset} ->
          {:noreply, assign(socket, :add_error, changeset_error(changeset))}
      end
    end
  end

  def handle_event("remove", %{"address" => address}, socket) do
    {:ok, _count} = Tracker.unsuppress(address)

    {:noreply,
     socket
     |> put_flash(:info, "#{address} released. Fair game once more.")
     |> load_suppressions()}
  end

  def handle_event("release_expired", _params, socket) do
    now = DateTime.utc_now()

    expired =
      Enum.filter(socket.assigns.suppressions, fn s ->
        match?(%DateTime{}, s.expires_at) and DateTime.compare(s.expires_at, now) == :lt
      end)

    Enum.each(expired, fn s -> Tracker.unsuppress(s.address) end)

    flash =
      case length(expired) do
        0 -> "No expired holds to release — the registry is current."
        1 -> "1 expired hold released back into the wild."
        n -> "#{n} expired holds released back into the wild."
      end

    {:noreply,
     socket
     |> put_flash(:info, flash)
     |> load_suppressions()}
  end

  # Fetches suppressions for the active reason filter, then applies the
  # address substring filter client-side (Tracker only supports exact address
  # match, never substring/ilike — see the Tracker moduledoc).
  defp load_suppressions(socket) do
    reason = socket.assigns.reason_filter
    query = socket.assigns.address_query

    filters = if reason, do: %{reason: reason}, else: %{}

    suppressions =
      filters
      |> Tracker.list_suppressions()
      |> filter_by_address(query)

    assign(socket, :suppressions, suppressions)
  end

  defp filter_by_address(suppressions, query) do
    case String.trim(query || "") do
      "" ->
        suppressions

      needle ->
        needle = String.downcase(needle)
        Enum.filter(suppressions, &String.contains?(String.downcase(&1.address || ""), needle))
    end
  end

  defp normalize_reason(reason) when reason in @valid_reasons, do: reason
  defp normalize_reason(_), do: nil

  defp patch_path(socket, reason, query) do
    query =
      []
      |> maybe_param("reason", reason)
      |> maybe_param("q", String.trim(query || ""))

    base = socket.assigns.dashboard_path <> "/suppressions"

    case query do
      [] -> base
      params -> base <> "?" <> URI.encode_query(params)
    end
  end

  defp maybe_param(params, _key, ""), do: params
  defp maybe_param(params, _key, nil), do: params
  defp maybe_param(params, key, value), do: params ++ [{key, value}]

  defp changeset_error(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%\{(\w+)\}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field} #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
    |> case do
      "" -> "That address couldn't be added."
      msg -> msg
    end
  end

  # ---- Rendering ------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :filters_active?,
        assigns.reason_filter != nil or String.trim(assigns.address_query) != ""
      )

    ~H"""
    <Layouts.app
      page_title="Do-Not-Disturb"
      active_nav={:do_not_disturb}
      dashboard_path={@dashboard_path}
      flash={@flash}
    >
      <div class="sq-filter-bar">
        <form id="sq-reason-filter" phx-change="filter_reason" phx-submit="filter_reason">
          <select class="sq-select" name="reason" aria-label="Filter by reason">
            <option value="" selected={@reason_filter == nil}>All reasons</option>
            <option
              :for={{value, label} <- reason_options()}
              value={value}
              selected={@reason_filter == value}
            >
              <%= label %>
            </option>
          </select>
        </form>

        <form id="sq-address-search" phx-change="search_address" phx-submit="search_address">
          <input
            type="text"
            class="sq-input"
            name="q"
            value={@address_query}
            placeholder="Search address…"
            aria-label="Search by address"
            phx-debounce="250"
          />
        </form>

        <span class="sq-filter-bar__spacer"></span>

        <button type="button" class="sq-btn sq-btn--ghost" phx-click="release_expired">
          Release expired
        </button>
      </div>

      <div
        style="background: var(--sq-bg-surface); border: 1px solid var(--sq-border); border-radius: var(--sq-radius); padding: 16px; margin-bottom: 24px; display: flex; flex-direction: column; gap: 12px;"
      >
        <span class="sq-microlabel">// Add to registry</span>
        <form
          id="sq-add-suppression"
          phx-submit="add_suppression"
          style="display: flex; gap: 8px; flex-wrap: wrap; align-items: flex-start;"
        >
          <input
            type="text"
            class="sq-input"
            name="address"
            placeholder="someone@example.com"
            aria-label="Address to suppress"
            style="flex: 1 1 220px; min-width: 0;"
          />
          <input
            type="text"
            class="sq-input"
            name="notes"
            placeholder="Notes (optional)"
            aria-label="Notes"
            style="flex: 2 1 260px; min-width: 0;"
          />
          <button type="submit" class="sq-btn sq-btn--primary">Hush address</button>
        </form>
        <p :if={@add_error} class="sq-mono" style="color: var(--sq-danger); font-size: 12px; margin: 0;">
          <%= @add_error %>
        </p>
      </div>

      <%= if @suppressions == [] do %>
        <%= if @filters_active? do %>
          <Components.empty_state
            title="No matches out here."
            copy="Nothing on the registry fits those filters. Widen the search and try again."
          />
        <% else %>
          <Components.empty_state
            title="Nobody has asked to be left alone."
            copy="The Squatch respects boundaries. Bounces and complaints will land here automatically."
          />
        <% end %>
      <% else %>
        <div class="sq-table-container">
          <table class="sq-table">
            <thead>
              <tr>
                <th>Address</th>
                <th>Reason</th>
                <th>Source</th>
                <th>Expires</th>
                <th>Logged</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={s <- @suppressions}>
                <td class="sq-mono"><%= s.address %></td>
                <td>
                  <span class={["sq-badge", reason_badge_class(s.reason)]}><%= reason_label(s.reason) %></span>
                </td>
                <td class="sq-table__timestamp">
                  <span :if={s.email_id}>linked to a sighting</span>
                  <span :if={is_nil(s.email_id)}>—</span>
                </td>
                <td class="sq-table__timestamp"><%= expires_label(s.expires_at) %></td>
                <td class="sq-table__timestamp"><%= format_ts(s.inserted_at) %></td>
                <td>
                  <button
                    type="button"
                    class="sq-btn sq-btn--danger"
                    phx-click="remove"
                    phx-value-address={s.address}
                    data-confirm={"Release #{s.address} from the Do-Not-Disturb registry?"}
                  >
                    Release
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  defp reason_options do
    [
      {"hard_bounce", "Hard bounce"},
      {"soft_bounce", "Soft bounce"},
      {"complaint", "Complaint"},
      {"manual", "Manual"}
    ]
  end

  defp reason_label("hard_bounce"), do: "Hard bounce"
  defp reason_label("soft_bounce"), do: "Soft bounce"
  defp reason_label("complaint"), do: "Complaint"
  defp reason_label("manual"), do: "Manual"
  defp reason_label(other), do: other

  # No dedicated badge CSS exists for suppression reasons, so we reuse the
  # closest existing semantic badge classes (see this file's report notes):
  #   hard_bounce/soft_bounce -> sq-badge--bounced
  #   complaint               -> sq-badge--complained
  #   manual                  -> sq-badge--sent
  defp reason_badge_class("hard_bounce"), do: "sq-badge--bounced"
  defp reason_badge_class("soft_bounce"), do: "sq-badge--bounced"
  defp reason_badge_class("complaint"), do: "sq-badge--complained"
  defp reason_badge_class("manual"), do: "sq-badge--sent"
  defp reason_badge_class(_), do: "sq-badge--sent"

  defp expires_label(nil), do: "permanent"

  defp expires_label(%DateTime{} = expires_at) do
    days = DateTime.diff(expires_at, DateTime.utc_now(), :second) |> div(86_400)

    cond do
      days < 0 -> "expired"
      days == 0 -> "expires today"
      days == 1 -> "expires in 1d"
      true -> "expires in #{days}d"
    end
  end

  defp format_ts(nil), do: "—"

  defp format_ts(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end
end
