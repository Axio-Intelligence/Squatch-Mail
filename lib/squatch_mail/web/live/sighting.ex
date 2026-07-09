defmodule SquatchMail.Web.Live.Sighting do
  @moduledoc """
  The Sighting inspector — `GET <dashboard_path>/sightings/:public_id`.

  Renders the "SIGHTING REPORT" for one email: a status/engagement summary,
  and five tabs — Preview, Text, Headers, Footprints (the event timeline),
  and Raw.

  ## Preview tab sandboxing

  `html_body` is arbitrary, third-party HTML the host application sent (or
  that arrived via SES capture) — it is untrusted content, not markup this
  app authored. It is rendered via an `<iframe srcdoc="...">` with
  `sandbox="allow-same-origin"` and **no** `allow-scripts` in the sandbox
  token list, and it is never passed through `raw/1`/`Phoenix.HTML.raw/1`
  into the surrounding page — only ever into the iframe's `srcdoc`
  attribute, which HEEx escapes as a normal attribute value (so embedded
  `"` / `<` in the HTML can't break out of the attribute or inject into the
  parent document). The combination means: even if `html_body` contains
  `<script>`, the browser's sandbox refuses to execute it (no
  `allow-scripts` token), and it can never execute in the parent frame's
  origin/context regardless (that's what an iframe boundary is for) — the
  worst case is inert markup rendered inside the sandboxed frame.

  ## Back-navigation preserves filters

  The "back to the trail" link reads a `?back=` query param (the page path
  suffix and filter query string `TrailLog` was showing when the user clicked
  into this sighting — see `TrailLog`'s `sighting_path/2`) and round-trips
  it, rather than hard-coding a plain link back to `dashboard_path`, so
  returning from the inspector lands on the same page (Trail Log, Sightings,
  Bounces, or Complaints) with its filters intact.
  """

  use Phoenix.LiveView

  alias SquatchMail.Tracker
  alias SquatchMail.Web.Components.Icons
  alias SquatchMail.Web.{Components, Layouts}

  @impl true
  def mount(%{"public_id" => public_id}, _session, socket) do
    socket =
      try do
        email = Tracker.get_email!(public_id)

        socket
        |> assign(:email, email)
        |> assign(:not_found?, false)
        |> assign(:active_tab, :preview)
      rescue
        Ecto.NoResultsError ->
          socket
          |> assign(:email, nil)
          |> assign(:not_found?, true)
          |> assign(:active_tab, :preview)
      end

    {:ok, assign(socket, :public_id, public_id)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :back_query, params["back"])}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  ## ---- Rendering ---------------------------------------------------------------

  @impl true
  def render(%{not_found?: true} = assigns) do
    ~H"""
    <Layouts.app
      page_title="Sighting"
      active_nav={:sightings}
      dashboard_path={@dashboard_path}
      flash={@flash}
    >
      <:actions>
        <.back_link dashboard_path={@dashboard_path} back_query={@back_query} />
      </:actions>

      <Components.empty_state
        title="This sighting is unconfirmed. Probably a bear."
        copy={"No sighting report for #{@public_id} — it may have been pruned or never existed."}
      />
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      page_title="Sighting Report"
      active_nav={:sightings}
      dashboard_path={@dashboard_path}
      flash={@flash}
    >
      <:actions>
        <.back_link dashboard_path={@dashboard_path} back_query={@back_query} />
      </:actions>

      <div style="display: flex; flex-direction: column; gap: 20px;">
        <.summary_card email={@email} />

        <div class="sq-sheet__tabs" style="padding: 0; border-bottom: 1px solid var(--sq-border);">
          <button
            :for={{tab, label} <- tabs()}
            type="button"
            class={["sq-sheet__tab", @active_tab == tab && "sq-sheet__tab--active"]}
            phx-click="switch_tab"
            phx-value-tab={tab}
          >
            <%= label %>
          </button>
        </div>

        <div>
          <.preview_tab :if={@active_tab == :preview} email={@email} />
          <.text_tab :if={@active_tab == :text} email={@email} />
          <.headers_tab :if={@active_tab == :headers} email={@email} />
          <.footprints_tab :if={@active_tab == :footprints} email={@email} />
          <.raw_tab :if={@active_tab == :raw} email={@email} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :dashboard_path, :string, required: true
  attr :back_query, :any, required: true

  defp back_link(assigns) do
    ~H"""
    <a class="sq-btn sq-btn--ghost" href={@dashboard_path <> (@back_query || "")}>
      ← Back to the trail
    </a>
    """
  end

  attr :email, :map, required: true

  defp summary_card(assigns) do
    ~H"""
    <div style="background: var(--sq-bg-surface); border: 1px solid var(--sq-border); border-radius: var(--sq-radius); padding: 20px; display: flex; flex-direction: column; gap: 12px;">
      <span class="sq-microlabel">// Sighting report</span>

      <div style="display: flex; flex-wrap: wrap; align-items: baseline; gap: 12px;">
        <span class="sq-mono" style="font-size: 16px;"><%= @email.subject || "(no subject)" %></span>
        <Components.status_badge status={@email.status} />
      </div>

      <div style="display: flex; flex-wrap: wrap; gap: 24px;">
        <div>
          <span class="sq-microlabel" style="display: block;">From</span>
          <span class="sq-mono"><%= @email.from_email %></span>
        </div>
        <div>
          <span class="sq-microlabel" style="display: block;">To</span>
          <span class="sq-mono"><%= recipients_summary(@email.recipients) %></span>
        </div>
        <div>
          <span class="sq-microlabel" style="display: block;">Sent</span>
          <span class="sq-mono"><%= format_ts(@email.sent_at) %></span>
        </div>
        <div :if={@email.error}>
          <span class="sq-microlabel" style="display: block; color: var(--sq-danger);">Error</span>
          <span class="sq-mono" style="color: var(--sq-danger);"><%= @email.error %></span>
        </div>
      </div>

      <div :if={@email.attachments != []}>
        <span class="sq-microlabel" style="display: block; margin-bottom: 4px;">Attachments</span>
        <div style="display: flex; flex-wrap: wrap; gap: 8px;">
          <span :for={a <- @email.attachments} class="sq-badge sq-badge--sent">
            <%= a.filename %> (<%= a.content_type %>, <%= a.size %>b)
          </span>
        </div>
      </div>
    </div>
    """
  end

  attr :email, :map, required: true

  defp preview_tab(assigns) do
    ~H"""
    <%= if @email.html_body do %>
      <div class="sq-sheet__preview-frame">
        <iframe
          srcdoc={@email.html_body}
          sandbox="allow-same-origin"
          style="width: 100%; height: 480px; border: none; display: block;"
          title="Sighting HTML preview (sandboxed)"
        >
        </iframe>
      </div>
    <% else %>
      <Components.empty_state title="No HTML body." copy="This sighting was sent without an HTML part." />
    <% end %>
    """
  end

  attr :email, :map, required: true

  defp text_tab(assigns) do
    ~H"""
    <%= if @email.text_body do %>
      <pre class="sq-mono" style="white-space: pre-wrap; background: var(--sq-bg-surface); border: 1px solid var(--sq-border); border-radius: var(--sq-radius); padding: 16px; font-size: 12px; overflow-x: auto;"><%= @email.text_body %></pre>
    <% else %>
      <Components.empty_state title="No text body." copy="This sighting was sent without a plain-text part." />
    <% end %>
    """
  end

  attr :email, :map, required: true

  defp headers_tab(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; gap: 20px;">
      <div>
        <span class="sq-microlabel" style="display: block; margin-bottom: 8px;">Headers</span>
        <.kv_table map={@email.headers} />
      </div>
      <div>
        <span class="sq-microlabel" style="display: block; margin-bottom: 8px;">Tags</span>
        <.kv_table map={@email.tags} />
      </div>
      <div>
        <span class="sq-microlabel" style="display: block; margin-bottom: 8px;">Provider options</span>
        <.kv_table map={@email.provider_options} />
      </div>
    </div>
    """
  end

  attr :map, :map, required: true

  defp kv_table(assigns) do
    ~H"""
    <%= if @map == %{} or is_nil(@map) do %>
      <p class="sq-mono" style="font-size: 12px; color: var(--sq-text-muted); margin: 0;">(none)</p>
    <% else %>
      <div class="sq-table-container">
        <table class="sq-table">
          <tbody>
            <tr :for={{key, value} <- @map}>
              <td class="sq-mono" style="color: var(--sq-text-muted); width: 200px;"><%= key %></td>
              <td class="sq-mono"><%= inspect(value) %></td>
            </tr>
          </tbody>
        </table>
      </div>
    <% end %>
    """
  end

  attr :email, :map, required: true

  defp footprints_tab(assigns) do
    ~H"""
    <%= if @email.events == [] do %>
      <Components.empty_state title="No footprints yet." copy="No SES events have arrived for this sighting." />
    <% else %>
      <div class="sq-timeline">
        <div :for={event <- @email.events} class="sq-timeline__item">
          <Icons.footprint class="sq-timeline__icon" style="width: 15px; height: 24px;" />
          <div class="sq-timeline__content">
            <span class="sq-timeline__label"><%= event_label(event) %></span>
            <span class="sq-timeline__timestamp"><%= format_ts(event.occurred_at) %></span>
            <span :if={event.recipient} class="sq-mono" style="font-size: 11px; color: var(--sq-text-muted);">
              <%= event.recipient %>
            </span>
            <span :if={event.url} class="sq-mono" style="font-size: 11px; color: var(--sq-text-muted); word-break: break-all;">
              → <%= event.url %>
            </span>
            <span :if={event.user_agent} class="sq-mono" style="font-size: 11px; color: var(--sq-text-muted);">
              <%= event.user_agent %>
            </span>
            <span :if={event.ip_address} class="sq-mono" style="font-size: 11px; color: var(--sq-text-muted);">
              <%= event.ip_address %>
            </span>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  attr :email, :map, required: true

  defp raw_tab(assigns) do
    ~H"""
    <pre class="sq-mono" style="white-space: pre-wrap; background: var(--sq-bg-surface); border: 1px solid var(--sq-border); border-radius: var(--sq-radius); padding: 16px; font-size: 12px; overflow-x: auto;"><%= inspect(@email, pretty: true, limit: :infinity) %></pre>
    """
  end

  ## ---- Helpers ------------------------------------------------------------------

  defp tabs do
    [
      {:preview, "Preview"},
      {:text, "Text"},
      {:headers, "Headers"},
      {:footprints, "Footprints"},
      {:raw, "Raw"}
    ]
  end

  defp recipients_summary([]), do: "(none)"
  defp recipients_summary(recipients), do: recipients |> Enum.map(& &1.address) |> Enum.join(", ")

  defp event_label(%{event_type: type}) do
    type
    |> to_string()
    |> String.capitalize()
  end

  defp format_ts(nil), do: "—"
  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
end
