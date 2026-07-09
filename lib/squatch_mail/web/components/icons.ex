defmodule SquatchMail.Web.Components.Icons do
  @moduledoc """
  The SquatchMail footprint mark and small outlined nav icons.

  The footprint (the landing page's `Footprint.astro` bigfoot track: long
  sole, arch details, five uneven toes) is the one recurring visual motif
  called for throughout DESIGN.md — loading spinner, empty states, and the
  event timeline all reuse this same `footprint/1` component so the mark
  stays consistent everywhere it appears, on the landing page and in the
  dashboard alike.
  """

  use Phoenix.Component

  attr :class, :string, default: nil
  attr :mirrored, :boolean, default: false
  attr :rest, :global

  @doc """
  Renders a single bigfoot track: long human-like sole, broad forefoot,
  heavy heel, uneven toes. Same geometry as the landing page's
  `Footprint.astro` — the one mark, everywhere. Pass `mirrored` for the
  opposite foot (walking-trail alternation).
  """
  def footprint(assigns) do
    ~H"""
    <svg
      class={["sq-footprint", @mirrored && "sq-footprint--mirrored", @class]}
      viewBox="0 0 48 76"
      fill="currentColor"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden="true"
      {@rest}
    >
      <path d="M10.2 25.8c1.8-6 7.8-9.5 15.6-9.2 8.3.3 15 4.3 17 10.4 1.8 5.5-.2 10.4-2.5 15.6-1.3 3-2.1 6-2.4 9.4-.5 5.7-.4 10.7-3.5 14.3-2.2 2.6-5.7 4.4-10 4.3-4.9-.1-8.8-2.1-11.2-5.1-3.3-4.2-3.1-10.2-3-16.1.1-4.4-1-7.8-2.2-11.4-1.4-4.2-.1-8.2 2.2-12.2Z" />
      <path
        opacity="0.25"
        d="M18.4 24.9c4.9-2.6 12.7-2.2 16.6 1.3 2.5 2.3 2.4 6.4 1.2 9.4-1.9 4.9-5.9 7.5-11.8 7.5-6.2 0-10.1-2.8-11.5-7.2-1.4-4.5 1.1-8.7 5.5-11Z"
      />
      <path
        opacity="0.2"
        d="M18.1 47.1c3.7 1.5 8.2 1.7 13.7.5M17.5 56.7c3.2 2.1 7.3 2.5 12.4 1.2"
        fill="none"
        stroke="currentColor"
        stroke-linecap="round"
        stroke-width="2"
      />
      <ellipse cx="8.7" cy="17.7" rx="4.1" ry="6.7" transform="rotate(-16 8.7 17.7)" />
      <ellipse cx="17.1" cy="9.9" rx="4.5" ry="6.8" transform="rotate(-8 17.1 9.9)" />
      <ellipse cx="25.8" cy="7.3" rx="4.4" ry="6.4" transform="rotate(2 25.8 7.3)" />
      <ellipse cx="34.1" cy="9.9" rx="4" ry="5.9" transform="rotate(12 34.1 9.9)" />
      <ellipse cx="41.3" cy="16.6" rx="3.5" ry="5.3" transform="rotate(22 41.3 16.6)" />
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
      <.footprint /><.footprint mirrored /><.footprint /><.footprint mirrored />
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
