defmodule SquatchMail.Web.Components do
  @moduledoc """
  Shared design-system components for SquatchMail dashboard pages: badges,
  stat cards, the live indicator, and empty states. Every visual rule here
  traces back to a rule in `DESIGN.md` — see that file before changing colors,
  radii, or copy.
  """

  use Phoenix.Component

  alias SquatchMail.Web.Components.Icons

  @doc """
  The pulsing "TRACKING LIVE" indicator shown in page headers.
  """
  def live_indicator(assigns) do
    ~H"""
    <span class="sq-live-indicator">
      <span class="sq-live-indicator__dot"></span> Tracking live
    </span>
    """
  end

  @doc """
  A status badge. One CSS class per status per DESIGN.md — never color alone
  conveys status; the text label is always rendered.
  """
  attr :status, :string, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={["sq-badge", "sq-badge--#{@status}"]}><%= @status %></span>
    """
  end

  @doc """
  One compact "Field Report" stat card: a mono label, a mono number, and an
  optional delta vs. the prior period.
  """
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :delta, :string, default: nil
  attr :delta_direction, :atom, default: nil, values: [nil, :up, :down]

  def stat_card(assigns) do
    ~H"""
    <div class="sq-stat-card">
      <span class="sq-stat-card__label"><%= @label %></span>
      <span class="sq-stat-card__value"><%= @value %></span>
      <span :if={@delta} class={[
        "sq-stat-card__delta",
        @delta_direction == :up && "sq-stat-card__delta--up",
        @delta_direction == :down && "sq-stat-card__delta--down"
      ]}>
        <%= @delta %>
      </span>
    </div>
    """
  end

  @doc """
  The five-card "Field Report" stat strip: Sightings (sent), Delivery rate,
  Open rate, Click rate, Bounce rate.
  """
  attr :sightings, :string, required: true
  attr :delivery_rate, :string, required: true
  attr :open_rate, :string, required: true
  attr :click_rate, :string, required: true
  attr :bounce_rate, :string, required: true

  def stat_strip(assigns) do
    ~H"""
    <div class="sq-stat-strip">
      <.stat_card label="Sightings" value={@sightings} />
      <.stat_card label="Delivery rate" value={@delivery_rate} />
      <.stat_card label="Open rate" value={@open_rate} />
      <.stat_card label="Click rate" value={@click_rate} />
      <.stat_card label="Bounce rate" value={@bounce_rate} />
    </div>
    """
  end

  @doc """
  A big-footprint empty state with field-journal copy, per DESIGN.md.
  """
  attr :title, :string, required: true
  attr :copy, :string, required: true

  def empty_state(assigns) do
    ~H"""
    <div class="sq-empty-state">
      <Icons.footprint class="sq-footprint" style="width: 56px; height: 56px;" />
      <span class="sq-empty-state__title"><%= @title %></span>
      <p class="sq-empty-state__copy"><%= @copy %></p>
    </div>
    """
  end
end
