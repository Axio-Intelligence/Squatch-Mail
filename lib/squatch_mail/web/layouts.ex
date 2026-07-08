defmodule SquatchMail.Web.Layouts do
  @moduledoc """
  Root and app layouts for the SquatchMail dashboard.

  `root/1` is the outermost HTML document (used as the LiveView
  `:root_layout`) and is responsible for loading the dashboard's
  self-contained CSS/JS bundle (see `SquatchMail.Web.AssetController`). It
  intentionally does *not* inherit the host application's own root layout —
  the dashboard is meant to look identical no matter which app embeds it,
  the same way LiveDashboard and Oban Web render inside their own document
  shell rather than the host's.

  `app/1` is the inner chrome every dashboard page renders through: the
  220px sidebar (logo, nav, session easter egg) plus the main content slot.
  """

  use Phoenix.Component

  alias SquatchMail.Web.Components.Icons

  embed_templates "layouts/*"

  attr :dashboard_path, :string, required: true
  slot :inner_block, required: true

  def root(assigns)

  attr :page_title, :string, required: true
  attr :active_nav, :atom, required: true
  attr :dashboard_path, :string, required: true
  attr :flash, :map, required: true
  slot :actions
  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :nav_items, nav_items())

    ~H"""
    <div class="sq-shell sq-root">
      <aside class="sq-sidebar">
        <a href={@dashboard_path} class="sq-sidebar__logo">
          <Icons.footprint style="width: 22px; height: 30px;" />
          <span class="sq-sidebar__wordmark">SQUATCHMAIL</span>
        </a>

        <nav class="sq-nav">
          <a
            :for={item <- @nav_items}
            href={@dashboard_path <> item.path}
            class={["sq-nav__item", @active_nav == item.id && "sq-nav__item--active"]}
          >
            <Icons.nav_icon name={item.icon} />
            <%= item.label %>
          </a>
        </nav>

        <div class="sq-sidebar__footer">
          <Icons.easter_egg />
        </div>
      </aside>

      <main class="sq-main">
        <div class="sq-page-header">
          <div class="sq-page-header__title-group">
            <h1 class="sq-page-title"><%= @page_title %></h1>
          </div>
          <div class="sq-page-header__actions">
            <%= render_slot(@actions) %>
          </div>
        </div>

        <.flash_group flash={@flash} />

        <%= render_slot(@inner_block) %>
      </main>
    </div>
    """
  end

  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div class="sq-flash-group" id="sq-flash-group">
      <p :if={info = Phoenix.Flash.get(@flash, :info)} class="sq-flash sq-flash--info">
        <%= info %>
      </p>
      <p :if={error = Phoenix.Flash.get(@flash, :error)} class="sq-flash sq-flash--error">
        <%= error %>
      </p>
    </div>
    """
  end

  defp nav_items do
    [
      %{id: :trail_log, label: "Trail Log", path: "", icon: :trail_log},
      %{id: :sightings, label: "Sightings", path: "/sightings", icon: :sightings},
      %{id: :bounces, label: "Bounces", path: "/bounces", icon: :bounces},
      %{id: :complaints, label: "Complaints", path: "/complaints", icon: :complaints},
      %{id: :do_not_disturb, label: "Do-Not-Disturb", path: "/suppressions", icon: :do_not_disturb},
      %{id: :base_camp, label: "Base Camp", path: "/base-camp", icon: :base_camp}
    ]
  end
end
