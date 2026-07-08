defmodule SquatchMail.Web.Live.TrailLog do
  @moduledoc """
  The Trail Log — SquatchMail's default landing page (`squatch_mail_dashboard`
  mounted at `/`) showing the live activity feed.

  This is currently a chrome-complete placeholder: it renders the full page
  shell (sidebar, "TRAIL LOG" header, live indicator, stat strip, empty
  state) with dummy data so the design is visible end-to-end before the
  pages agent wires up real queries against `SquatchMail.Email` /
  `SquatchMail.EmailEvent`.
  """

  use Phoenix.LiveView

  alias SquatchMail.Web.{Components, Layouts}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

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
      </:actions>

      <Components.stat_strip
        sightings="0"
        delivery_rate="—"
        open_rate="—"
        click_rate="—"
        bounce_rate="—"
      />

      <Components.empty_state
        title="No sightings yet. The forest is quiet… too quiet."
        copy="Once your app sends its first email, its tracks will show up here in real time."
      />
    </Layouts.app>
    """
  end
end
