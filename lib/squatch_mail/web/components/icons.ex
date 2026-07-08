defmodule SquatchMail.Web.Components.Icons do
  @moduledoc """
  The SquatchMail footprint mark and small outlined nav icons.

  The footprint (5 toes + pad) is the one recurring visual motif called for
  throughout DESIGN.md — logo, nav, loading spinner, empty states, and the
  session easter egg all reuse this same `footprint/1` component so the mark
  stays consistent everywhere it appears.
  """

  use Phoenix.Component

  attr :class, :string, default: nil
  attr :rest, :global

  @doc """
  Renders a single sasquatch footprint: one pad + five toes.
  """
  def footprint(assigns) do
    ~H"""
    <svg
      class={["sq-footprint", @class]}
      viewBox="0 0 32 44"
      fill="currentColor"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden="true"
      {@rest}
    >
      <ellipse cx="16" cy="29" rx="10.5" ry="14" />
      <ellipse cx="4.5" cy="8" rx="3.1" ry="4.3" transform="rotate(-18 4.5 8)" />
      <ellipse cx="11.4" cy="3.6" rx="3.2" ry="4.6" transform="rotate(-8 11.4 3.6)" />
      <ellipse cx="19" cy="3" rx="3.2" ry="4.6" transform="rotate(4 19 3)" />
      <ellipse cx="26.2" cy="4.8" rx="3.1" ry="4.4" transform="rotate(14 26.2 4.8)" />
      <ellipse cx="30.8" cy="10.5" rx="2.8" ry="4" transform="rotate(28 30.8 10.5)" />
    </svg>
    """
  end

  @doc """
  Four footprints used together as the "walking tracks" loading spinner,
  paired with the `.sq-loading-label` mono caption in callers (e.g.
  `FOLLOWING TRACKS…`).
  """
  attr :label, :string, default: "Following tracks…"

  def spinner(assigns) do
    ~H"""
    <span class="sq-spinner" role="status" aria-label={@label}>
      <.footprint /><.footprint /><.footprint /><.footprint />
    </span>
    """
  end

  attr :name, :atom, required: true
  attr :class, :string, default: nil

  @doc """
  Small outlined nav-rail icons. Deliberately simple single-path glyphs (not
  the footprint mark, which is reserved for the logo/spinner/empty states) so
  the sidebar stays legible at 16px.
  """
  def nav_icon(%{name: :trail_log} = assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" d="M4 12h4l2-7 4 14 2-7h4" />
    </svg>
    """
  end

  def nav_icon(%{name: :sightings} = assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
      <rect x="3.5" y="5.5" width="17" height="13" rx="1.5" />
      <path stroke-linecap="round" stroke-linejoin="round" d="M4 7l8 6 8-6" />
    </svg>
    """
  end

  def nav_icon(%{name: :bounces} = assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" d="M4 17l4-9 4 6 3-4 5 7" />
    </svg>
    """
  end

  def nav_icon(%{name: :complaints} = assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" d="M12 4l8 15H4l8-15z" />
      <path stroke-linecap="round" d="M12 10v3.5" />
      <circle cx="12" cy="16.5" r="0.6" fill="currentColor" stroke="none" />
    </svg>
    """
  end

  def nav_icon(%{name: :do_not_disturb} = assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
      <circle cx="12" cy="12" r="8" />
      <path stroke-linecap="round" d="M6.5 6.5l11 11" />
    </svg>
    """
  end

  def nav_icon(%{name: :base_camp} = assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" d="M4 19l8-13 8 13" />
      <path stroke-linecap="round" stroke-linejoin="round" d="M9.5 19l2.5-6 2.5 6" />
    </svg>
    """
  end

  def nav_icon(%{name: :field_guide} = assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" d="M4 5.5c2-1 5-1 7 0v13c-2-1-5-1-7 0v-13z" />
      <path stroke-linecap="round" stroke-linejoin="round" d="M20 5.5c-2-1-5-1-7 0v13c2-1 5-1 7 0v-13z" />
    </svg>
    """
  end

  @doc """
  The tiny sasquatch silhouette that walks across the sidebar footer once per
  session. Purely decorative; `prefers-reduced-motion` disables the CSS
  animation that moves it (see `assets/css/squatch_mail.css` `.sq-easter-egg`).
  """
  attr :class, :string, default: nil

  def easter_egg(assigns) do
    ~H"""
    <svg class={["sq-easter-egg", @class]} viewBox="0 0 24 24" fill="currentColor" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
      <ellipse cx="12" cy="7" rx="3.4" ry="3.8" />
      <path d="M7 11c-1.5 0-2.5 1.8-2 3.4l1.4 4.6c.3 1 1.2 1.7 2.2 1.7h6.8c1 0 1.9-.7 2.2-1.7l1.4-4.6c.5-1.6-.5-3.4-2-3.4H7z" />
      <path d="M6 15l-3 2M18 15l3 2" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" />
    </svg>
    """
  end
end
