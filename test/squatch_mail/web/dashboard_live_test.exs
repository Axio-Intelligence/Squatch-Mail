defmodule SquatchMail.Web.DashboardLiveTest do
  @moduledoc """
  Chrome-level smoke test shared across every dashboard LiveView: the
  sidebar, its six nav sections, and the active-item state. Page-specific
  behavior lives in each page's own test file (`trail_log_live_test.exs`,
  `sighting_live_test.exs`, `suppressions_live_test.exs`,
  `base_camp_live_test.exs`).
  """

  use SquatchMail.Web.WebCase, async: false

  setup do
    Application.delete_env(:squatch_mail, :basic_auth)
    Application.put_env(:squatch_mail, :allow_unauthenticated, true)
    :ok
  end

  test "sidebar nav renders all six sections with the current page marked active", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/squatch")

    # The wordmark is split so "MAIL" carries the chartreuse accent, matching
    # the landing page's logo lockup.
    assert html =~ ~s(SQUATCH<span class="sq-sidebar__wordmark-accent">MAIL</span>)
    assert html =~ "sq-sidebar__logo-img"
    assert html =~ "Trail Log"
    assert html =~ "Sightings"
    assert html =~ "Bounces"
    assert html =~ "Complaints"
    assert html =~ "Do-Not-Disturb"
    assert html =~ "Base Camp"
    assert html =~ "sq-nav__item--active"
  end
end
