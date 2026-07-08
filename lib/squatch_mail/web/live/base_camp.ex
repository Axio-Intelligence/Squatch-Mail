defmodule SquatchMail.Web.Live.BaseCamp do
  @moduledoc """
  Base Camp — `GET <dashboard_path>/base-camp`, the SES connection/setup page.

  Placeholder page: renders the dashboard chrome with an empty state. The
  SES-integration agent will replace this with the "Connect SES" flow
  (credentials, region, quota sync, identity/DKIM checks) against
  `SquatchMail.Source`.
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
      page_title="Base Camp"
      active_nav={:base_camp}
      dashboard_path={@dashboard_path}
      flash={@flash}
    >
      <Components.empty_state
        title="No camp pitched yet."
        copy="Connect your SES credentials to start tracking sightings."
      />
    </Layouts.app>
    """
  end
end
