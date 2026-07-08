defmodule SquatchMail.Web.Live.BaseCamp do
  @moduledoc """
  Base Camp — `GET <dashboard_path>/base-camp`, the SES connection/setup page.

  Renders the connection-config form (region + credentials mode + optional
  static keys), a provisioning action, the SES sending quota, and the list of
  sending identities with their DKIM/DNS status.

  ## Missing credentials is a normal state

  Every SES call can return `{:error, :missing_credentials}` — this is the
  expected steady state for a fresh install with no AWS credentials. It never
  crashes `mount`/`handle_event`/`handle_async`; instead the quota and
  identity sections render a "Set up camp" onboarding empty state (copy
  "Connect your SES credentials to start tracking sightings.") while the
  connection-config form — which never touches AWS — stays fully usable so an
  operator can enter credentials in the first place.

  ## Webhook base URL

  `SES.provision/1` needs a full, publicly-reachable webhook URL, but neither
  `Source` nor the app config has a field to store the host's public base URL.
  So we take it as a plain form field ("Webhook base URL") kept only in socket
  assigns for the session, and build the full path as
  `base_url <> @dashboard_path <> "/webhooks/sns/" <> source.webhook_token`.
  Persisting this would need a new `Source` field (a follow-up — `source.ex`
  is out of this file's territory).
  """

  use Phoenix.LiveView

  alias SquatchMail.{SES, Source, Tracker}
  alias SquatchMail.Web.Components.Icons
  alias SquatchMail.Web.{Components, Layouts}

  @impl true
  def mount(_params, _session, socket) do
    source = Tracker.get_or_create_source()

    socket =
      socket
      |> assign(:source, source)
      |> assign(:webhook_base_url, "")
      |> assign(:provisioning?, false)
      |> assign(:quota_syncing?, false)
      |> assign(:quota_locked?, false)
      |> assign(:identities, nil)
      |> assign(:identities_loading?, false)
      |> assign(:identities_error, nil)
      |> assign(:dns_checks, %{})
      |> load_quota()
      |> maybe_load_identities()

    {:ok, socket}
  end

  # Quota: only sync when we have a source; degrade gracefully on
  # missing_credentials (lock the card) and surface any other error via flash.
  defp load_quota(socket) do
    case SES.ensure_quota_synced(socket.assigns.source) do
      {:ok, %Source{} = source} ->
        socket
        |> assign(:source, source)
        |> assign(:quota_locked?, false)

      {:error, :missing_credentials} ->
        assign(socket, :quota_locked?, true)

      {:error, reason} ->
        socket
        |> assign(:quota_locked?, false)
        |> put_flash(:error, "The trail went cold: #{reason}")
    end
  end

  # Kick off identity listing asynchronously (only when connected) so mount
  # isn't blocked on the network. When credentials are missing, skip it and
  # let the section render the onboarding state.
  defp maybe_load_identities(socket) do
    if connected?(socket) and not socket.assigns.quota_locked? do
      socket
      |> assign(:identities_loading?, true)
      |> start_async(:list_identities, fn -> SES.list_identities() end)
    else
      socket
    end
  end

  ## ---- Events ---------------------------------------------------------------

  @impl true
  def handle_event("save_source", %{"source" => params}, socket) do
    attrs = Map.take(params, ~w(region credentials_mode access_key_id secret_access_key))

    # Never overwrite a stored secret with the masked placeholder we render.
    attrs =
      if masked?(params["secret_access_key"]) do
        Map.delete(attrs, "secret_access_key")
      else
        attrs
      end

    case Tracker.update_source(attrs) do
      {:ok, source} ->
        {:noreply,
         socket
         |> assign(:source, source)
         |> put_flash(:info, "Base Camp settings saved.")
         |> load_quota()}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Couldn't save: #{changeset_error(changeset)}")}
    end
  end

  def handle_event("update_webhook_base_url", %{"webhook_base_url" => url}, socket) do
    {:noreply, assign(socket, :webhook_base_url, url)}
  end

  def handle_event("provision", params, socket) do
    base_url = String.trim(params["webhook_base_url"] || socket.assigns.webhook_base_url || "")
    source = socket.assigns.source

    webhook_url =
      base_url <> socket.assigns.dashboard_path <> "/webhooks/sns/" <> source.webhook_token

    socket =
      socket
      |> assign(:webhook_base_url, base_url)
      |> assign(:provisioning?, true)
      |> start_async(:provision, fn -> SES.provision(webhook_url) end)

    {:noreply, socket}
  end

  def handle_event("sync_quota", _params, socket) do
    socket =
      socket
      |> assign(:quota_syncing?, true)
      |> start_async(:sync_quota, fn -> SES.sync_quota() end)

    {:noreply, socket}
  end

  def handle_event("recheck_dns", %{"identity" => identity_name}, socket) do
    identity = Enum.find(socket.assigns.identities || [], &(&1.identity == identity_name))

    if identity do
      records = SES.dns_records_for(identity)

      socket =
        start_async(socket, {:check_dns, identity_name}, fn ->
          {identity_name, SES.check_dns(records)}
        end)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  ## ---- Async results --------------------------------------------------------

  @impl true
  def handle_async(:provision, {:ok, {:ok, %Source{} = source}}, socket) do
    {:noreply,
     socket
     |> assign(:source, source)
     |> assign(:provisioning?, false)
     |> assign(:quota_locked?, false)
     |> put_flash(:info, "Camp pitched. SES is now radioing sightings back to us.")
     |> maybe_load_identities()}
  end

  def handle_async(:provision, {:ok, {:error, :missing_credentials}}, socket) do
    {:noreply,
     socket
     |> assign(:provisioning?, false)
     |> assign(:quota_locked?, true)}
  end

  def handle_async(:provision, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:provisioning?, false)
     |> put_flash(:error, "The trail went cold: #{inspect(reason)}")}
  end

  def handle_async(:provision, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:provisioning?, false)
     |> put_flash(:error, "The trail went cold: #{inspect(reason)}")}
  end

  def handle_async(:sync_quota, {:ok, {:ok, %Source{} = source}}, socket) do
    {:noreply,
     socket
     |> assign(:source, source)
     |> assign(:quota_syncing?, false)
     |> assign(:quota_locked?, false)
     |> put_flash(:info, "Quota refreshed.")}
  end

  def handle_async(:sync_quota, {:ok, {:error, :missing_credentials}}, socket) do
    {:noreply,
     socket
     |> assign(:quota_syncing?, false)
     |> assign(:quota_locked?, true)}
  end

  def handle_async(:sync_quota, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:quota_syncing?, false)
     |> put_flash(:error, "The trail went cold: #{inspect(reason)}")}
  end

  def handle_async(:sync_quota, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:quota_syncing?, false)
     |> put_flash(:error, "The trail went cold: #{inspect(reason)}")}
  end

  def handle_async(:list_identities, {:ok, {:ok, identities}}, socket) do
    {:noreply,
     socket
     |> assign(:identities, identities)
     |> assign(:identities_loading?, false)
     |> assign(:identities_error, nil)}
  end

  def handle_async(:list_identities, {:ok, {:error, :missing_credentials}}, socket) do
    {:noreply,
     socket
     |> assign(:identities_loading?, false)
     |> assign(:quota_locked?, true)}
  end

  def handle_async(:list_identities, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:identities_loading?, false)
     |> assign(:identities_error, "The trail went cold: #{inspect(reason)}")}
  end

  def handle_async(:list_identities, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:identities_loading?, false)
     |> assign(:identities_error, "The trail went cold: #{inspect(reason)}")}
  end

  def handle_async({:check_dns, _identity_name}, {:ok, {name, checked}}, socket) do
    {:noreply, update(socket, :dns_checks, &Map.put(&1, name, checked))}
  end

  def handle_async({:check_dns, identity_name}, {:exit, reason}, socket) do
    {:noreply,
     put_flash(socket, :error, "DNS re-check for #{identity_name} went cold: #{inspect(reason)}")}
  end

  ## ---- Rendering ------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      page_title="Base Camp"
      active_nav={:base_camp}
      dashboard_path={@dashboard_path}
      flash={@flash}
    >
      <div style="display: flex; flex-direction: column; gap: 24px;">
        <.connection_card source={@source} />
        <.provision_card
          source={@source}
          dashboard_path={@dashboard_path}
          webhook_base_url={@webhook_base_url}
          provisioning?={@provisioning?}
        />
        <.webhook_card
          source={@source}
          dashboard_path={@dashboard_path}
          webhook_base_url={@webhook_base_url}
        />

        <%= if @quota_locked? do %>
          <.card>
            <span class="sq-microlabel">// Field report</span>
            <Components.empty_state
              title="No camp pitched yet."
              copy="Connect your SES credentials to start tracking sightings."
            />
          </.card>
        <% else %>
          <.quota_card source={@source} quota_syncing?={@quota_syncing?} />
          <.identities_card
            identities={@identities}
            identities_loading?={@identities_loading?}
            identities_error={@identities_error}
            dns_checks={@dns_checks}
          />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # A generic surface panel — there is no card/panel CSS class in this project
  # (see report notes), so we build it from inline styles matching the
  # `.sq-table-container` treatment (surface bg, hairline border, radius).
  slot :inner_block, required: true

  defp card(assigns) do
    ~H"""
    <div style="background: var(--sq-bg-surface); border: 1px solid var(--sq-border); border-radius: var(--sq-radius); padding: 20px; display: flex; flex-direction: column; gap: 16px;">
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  attr :source, Source, required: true

  defp connection_card(assigns) do
    ~H"""
    <.card>
      <span class="sq-microlabel">// Connection</span>
      <form id="sq-source-form" phx-submit="save_source" phx-change="save_source" style="display: flex; flex-direction: column; gap: 12px;">
        <label style="display: flex; flex-direction: column; gap: 4px;">
          <span class="sq-microlabel">Region</span>
          <input type="text" class="sq-input" name="source[region]" value={@source.region} />
        </label>

        <label style="display: flex; flex-direction: column; gap: 4px;">
          <span class="sq-microlabel">Credentials mode</span>
          <select class="sq-select" name="source[credentials_mode]">
            <option value="ambient" selected={@source.credentials_mode == "ambient"}>
              Ambient (AWS env vars)
            </option>
            <option value="static" selected={@source.credentials_mode == "static"}>
              Static (stored keys)
            </option>
          </select>
        </label>

        <div :if={@source.credentials_mode == "static"} style="display: flex; flex-direction: column; gap: 12px;">
          <label style="display: flex; flex-direction: column; gap: 4px;">
            <span class="sq-microlabel">Access key ID</span>
            <input type="text" class="sq-input sq-mono" name="source[access_key_id]" value={@source.access_key_id} />
          </label>
          <label style="display: flex; flex-direction: column; gap: 4px;">
            <span class="sq-microlabel">Secret access key</span>
            <input
              type="text"
              class="sq-input sq-mono"
              name="source[secret_access_key]"
              value={mask_secret(@source.secret_access_key)}
              placeholder="AWS secret access key"
            />
          </label>
        </div>

        <div>
          <button type="submit" class="sq-btn sq-btn--primary">Save settings</button>
        </div>
      </form>
    </.card>
    """
  end

  attr :source, Source, required: true
  attr :dashboard_path, :string, required: true
  attr :webhook_base_url, :string, required: true
  attr :provisioning?, :boolean, required: true

  defp provision_card(assigns) do
    ~H"""
    <.card>
      <span class="sq-microlabel">// Provision SES</span>
      <p class="sq-mono" style="font-size: 12px; color: var(--sq-text-muted); margin: 0;">
        One click wires up a configuration set, an SNS topic, and an HTTPS subscription pointed at this dashboard's webhook.
      </p>
      <form id="sq-provision-form" phx-submit="provision" phx-change="update_webhook_base_url" style="display: flex; flex-direction: column; gap: 12px;">
        <label style="display: flex; flex-direction: column; gap: 4px;">
          <span class="sq-microlabel">Webhook base URL</span>
          <input
            type="text"
            class="sq-input sq-mono"
            name="webhook_base_url"
            value={@webhook_base_url}
            placeholder="https://myapp.example.com"
          />
        </label>
        <div style="display: flex; align-items: center; gap: 12px;">
          <button type="submit" class="sq-btn sq-btn--primary" disabled={@provisioning?}>
            Provision SES
          </button>
          <span :if={@provisioning?} style="display: inline-flex; align-items: center; gap: 8px;">
            <Icons.spinner label="Following tracks…" />
            <span class="sq-loading-label">Following tracks…</span>
          </span>
        </div>
      </form>
    </.card>
    """
  end

  attr :source, Source, required: true
  attr :dashboard_path, :string, required: true
  attr :webhook_base_url, :string, required: true

  defp webhook_card(assigns) do
    ~H"""
    <.card>
      <span class="sq-microlabel">// Webhook endpoint</span>
      <p
        class="sq-mono"
        style="font-size: 12px; color: var(--sq-text); background: var(--sq-bg-base); border: 1px solid var(--sq-border); border-radius: var(--sq-radius); padding: 12px; overflow-x: auto; margin: 0; user-select: all;"
      >
        <%= webhook_url(@webhook_base_url, @dashboard_path, @source.webhook_token) %>
      </p>
      <p class="sq-microlabel" style="margin: 0;">The forest is listening.</p>
    </.card>
    """
  end

  attr :source, Source, required: true
  attr :quota_syncing?, :boolean, required: true

  defp quota_card(assigns) do
    assigns = assign(assigns, :quota, assigns.source.quota || %{})

    ~H"""
    <.card>
      <div style="display: flex; align-items: center; justify-content: space-between; gap: 12px;">
        <span class="sq-microlabel">// Field report — sending quota</span>
        <div style="display: flex; align-items: center; gap: 12px;">
          <span :if={@quota_syncing?} style="display: inline-flex; align-items: center; gap: 6px;">
            <Icons.spinner label="Following tracks…" />
            <span class="sq-loading-label">Following tracks…</span>
          </span>
          <button type="button" class="sq-btn sq-btn--ghost" phx-click="sync_quota" disabled={@quota_syncing?}>
            Sync now
          </button>
        </div>
      </div>

      <%= if @quota == %{} do %>
        <p class="sq-mono" style="font-size: 12px; color: var(--sq-text-muted); margin: 0;">
          No quota fetched yet. Hit "Sync now" to radio SES for the numbers.
        </p>
      <% else %>
        <div>
          <span class={["sq-badge", sandbox_badge_class(@quota)]}><%= sandbox_label(@quota) %></span>
        </div>

        <div class="sq-stat-strip" style="grid-template-columns: repeat(3, minmax(0, 1fr));">
          <div class="sq-stat-card">
            <span class="sq-stat-card__label">Max 24h send</span>
            <span class="sq-stat-card__value"><%= num(Map.get(@quota, "max_24_hour_send")) %></span>
          </div>
          <div class="sq-stat-card">
            <span class="sq-stat-card__label">Sent last 24h</span>
            <span class="sq-stat-card__value"><%= num(Map.get(@quota, "sent_last_24_hours")) %></span>
          </div>
          <div class="sq-stat-card">
            <span class="sq-stat-card__label">Max send rate/s</span>
            <span class="sq-stat-card__value"><%= num(Map.get(@quota, "max_send_rate")) %></span>
          </div>
        </div>

        <div>
          <div style="height: 8px; border-radius: 999px; background: var(--sq-bg-highlight); overflow: hidden;">
            <div style={"height: 100%; width: #{quota_percent(@quota)}%; background: var(--sq-accent);"}></div>
          </div>
          <span class="sq-microlabel" style="display: block; margin-top: 6px;">
            <%= quota_percent(@quota) %>% of daily quota used · checked <%= checked_ago(@source.quota_checked_at) %>
          </span>
        </div>
      <% end %>
    </.card>
    """
  end

  attr :identities, :any, required: true
  attr :identities_loading?, :boolean, required: true
  attr :identities_error, :any, required: true
  attr :dns_checks, :map, required: true

  defp identities_card(assigns) do
    ~H"""
    <.card>
      <span class="sq-microlabel">// Sending identities</span>

      <p :if={@identities_error} class="sq-mono" style="color: var(--sq-danger); font-size: 12px; margin: 0;">
        <%= @identities_error %>
      </p>

      <%= cond do %>
        <% @identities_loading? -> %>
          <span style="display: inline-flex; align-items: center; gap: 8px;">
            <Icons.spinner label="Following tracks…" />
            <span class="sq-loading-label">Following tracks…</span>
          </span>
        <% @identities in [nil, []] -> %>
          <p class="sq-mono" style="font-size: 12px; color: var(--sq-text-muted); margin: 0;">
            No sending identities found yet.
          </p>
        <% true -> %>
          <div class="sq-table-container">
            <table class="sq-table">
              <thead>
                <tr>
                  <th>Identity</th>
                  <th>Verified</th>
                  <th>DKIM</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for identity <- @identities do %>
                  <tr>
                    <td class="sq-mono"><%= identity.identity %></td>
                    <td>
                      <span class={["sq-badge", verified_badge_class(identity.verified?)]}>
                        <%= if identity.verified?, do: "verified", else: "unverified" %>
                      </span>
                    </td>
                    <td>
                      <span class={["sq-badge", dkim_badge_class(identity.dkim_status)]}>
                        <%= dkim_label(identity.dkim_status) %>
                      </span>
                    </td>
                    <td>
                      <button
                        :if={identity.type == :domain}
                        type="button"
                        class="sq-btn sq-btn--ghost"
                        phx-click="recheck_dns"
                        phx-value-identity={identity.identity}
                      >
                        Re-check DNS
                      </button>
                    </td>
                  </tr>
                  <tr :if={identity.type == :domain}>
                    <td colspan="4" style="background: var(--sq-bg-base);">
                      <.dns_records
                        identity={identity}
                        checked={Map.get(@dns_checks, identity.identity)}
                      />
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
      <% end %>
    </.card>
    """
  end

  attr :identity, :map, required: true
  attr :checked, :any, required: true

  defp dns_records(assigns) do
    assigns = assign(assigns, :records, assigns.checked || SES.dns_records_for(assigns.identity))

    ~H"""
    <div style="display: flex; flex-direction: column; gap: 8px;">
      <span class="sq-microlabel">Publish these DNS records</span>
      <%= for record <- @records do %>
        <div style="display: flex; flex-wrap: wrap; align-items: center; gap: 8px;">
          <span class="sq-badge sq-badge--sent"><%= record.type |> to_string() |> String.upcase() %></span>
          <span :if={Map.has_key?(record, :status)} class={["sq-badge", dns_badge_class(record.status)]}>
            <%= record.status %>
          </span>
          <code class="sq-mono" style="user-select: all; color: var(--sq-text-muted); font-size: 12px;">
            <%= record.name %>
          </code>
          <span class="sq-mono" style="color: var(--sq-text-muted);">→</span>
          <code class="sq-mono" style="user-select: all; color: var(--sq-text); font-size: 12px;">
            <%= record.value %>
          </code>
          <span
            :if={Map.get(record, :found, []) != []}
            class="sq-mono"
            style="color: var(--sq-ember); font-size: 11px;"
          >
            found: <%= Enum.join(record.found, ", ") %>
          </span>
        </div>
      <% end %>
    </div>
    """
  end

  ## ---- Helpers --------------------------------------------------------------

  defp webhook_url(base_url, dashboard_path, token) do
    base = String.trim(base_url || "")
    base <> dashboard_path <> "/webhooks/sns/" <> (token || "")
  end

  # Renders the stored secret masked to the last 4 chars, never the full value.
  defp mask_secret(nil), do: ""
  defp mask_secret(""), do: ""

  defp mask_secret(secret) when is_binary(secret) do
    last4 = String.slice(secret, -4, 4)
    String.duplicate("•", 8) <> last4
  end

  # True when the value is the masked placeholder we rendered (so we don't
  # write it back over the real stored secret on save).
  defp masked?(nil), do: false
  defp masked?(value) when is_binary(value), do: String.contains?(value, "•")

  # Sandbox vs production badge: reuse sq-badge--delivered for Production and
  # sq-badge--delayed for Sandbox (see report notes).
  defp sandbox_badge_class(quota) do
    if production?(quota), do: "sq-badge--delivered", else: "sq-badge--delayed"
  end

  defp sandbox_label(quota) do
    if production?(quota), do: "production", else: "sandbox"
  end

  defp production?(quota) do
    Map.get(quota, "production_access_enabled") == true or
      Map.get(quota, "sending_enabled") == true
  end

  # verified/unverified reuse sq-badge--delivered / sq-badge--rejected.
  defp verified_badge_class(true), do: "sq-badge--delivered"
  defp verified_badge_class(_), do: "sq-badge--rejected"

  # DKIM status reuses delivered (success) / delayed (pending) / rejected.
  defp dkim_badge_class(status) when status in ["SUCCESS", "success"], do: "sq-badge--delivered"
  defp dkim_badge_class(status) when status in ["PENDING", "pending"], do: "sq-badge--delayed"
  defp dkim_badge_class(nil), do: "sq-badge--rejected"
  defp dkim_badge_class(_), do: "sq-badge--rejected"

  defp dkim_label(nil), do: "no dkim"
  defp dkim_label(status), do: status |> to_string() |> String.downcase()

  # DNS check statuses reuse delivered (pass) / delayed (warn) / rejected (missing).
  defp dns_badge_class(:pass), do: "sq-badge--delivered"
  defp dns_badge_class(:warn), do: "sq-badge--delayed"
  defp dns_badge_class(:missing), do: "sq-badge--rejected"
  defp dns_badge_class(_), do: "sq-badge--sent"

  defp num(nil), do: "—"
  defp num(value) when is_float(value), do: value |> round() |> Integer.to_string()
  defp num(value) when is_integer(value), do: Integer.to_string(value)
  defp num(value), do: to_string(value)

  defp quota_percent(quota) do
    max = to_number(Map.get(quota, "max_24_hour_send"))
    sent = to_number(Map.get(quota, "sent_last_24_hours"))

    cond do
      is_nil(max) or max <= 0 -> 0
      is_nil(sent) -> 0
      true -> (sent / max * 100) |> min(100.0) |> Float.round(1)
    end
  end

  defp to_number(nil), do: nil
  defp to_number(n) when is_number(n), do: n
  defp to_number(_), do: nil

  # Relative "checked Nh ago" with plain DateTime.diff (no Timex dependency).
  defp checked_ago(nil), do: "never"

  defp checked_ago(%DateTime{} = checked_at) do
    seconds = DateTime.diff(DateTime.utc_now(), checked_at, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{ago_unit(div(seconds, 60), "minute")} ago"
      seconds < 86_400 -> "#{ago_unit(div(seconds, 3600), "hour")} ago"
      true -> "#{ago_unit(div(seconds, 86_400), "day")} ago"
    end
  end

  defp ago_unit(1, unit), do: "1 #{unit}"
  defp ago_unit(n, unit), do: "#{n} #{unit}s"

  defp changeset_error(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%\{(\w+)\}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field} #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
    |> case do
      "" -> "invalid settings"
      msg -> msg
    end
  end
end
