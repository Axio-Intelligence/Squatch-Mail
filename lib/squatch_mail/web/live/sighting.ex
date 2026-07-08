defmodule SquatchMail.Web.Live.Sighting do
  @moduledoc """
  The Sighting inspector — `GET <dashboard_path>/sightings/:public_id`.

  Placeholder route stub: renders the dashboard chrome with an empty state.
  The pages agent will replace this with the full "SIGHTING REPORT" side
  sheet (rendered HTML preview, headers, footprint/event timeline, raw MIME)
  described in DESIGN.md.
  """

  use Phoenix.LiveView

  alias SquatchMail.Web.{Components, Layouts}

  @impl true
  def mount(%{"public_id" => public_id}, _session, socket) do
    {:ok, assign(socket, :public_id, public_id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      page_title="Sighting"
      active_nav={:sightings}
      dashboard_path={@dashboard_path}
      flash={@flash}
    >
      <Components.empty_state
        title="This sighting is unconfirmed. Probably a bear."
        copy={"No sighting report for #{@public_id} yet — the inspector is still being built."}
      />
    </Layouts.app>
    """
  end
end
