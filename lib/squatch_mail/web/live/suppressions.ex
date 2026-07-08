defmodule SquatchMail.Web.Live.Suppressions do
  @moduledoc """
  The Do-Not-Disturb registry — `GET <dashboard_path>/suppressions`.

  Placeholder page: renders the dashboard chrome with the suppressions
  empty state from DESIGN.md. The pages agent will replace this with the
  real listing against `SquatchMail.Suppression`.
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
      page_title="Do-Not-Disturb"
      active_nav={:do_not_disturb}
      dashboard_path={@dashboard_path}
      flash={@flash}
    >
      <Components.empty_state
        title="Nobody has asked to be left alone."
        copy="The Squatch respects boundaries. Bounces and complaints will land here automatically."
      />
    </Layouts.app>
    """
  end
end
