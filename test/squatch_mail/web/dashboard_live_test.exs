defmodule SquatchMail.Web.DashboardLiveTest do
  @moduledoc """
  Mounts each placeholder dashboard LiveView end-to-end (dev-mode / open
  access) to confirm the router macro, layout, and chrome all render
  together without error.
  """

  use SquatchMail.Web.WebCase, async: false

  setup do
    Application.delete_env(:squatch_mail, :basic_auth)
    Application.put_env(:squatch_mail, :allow_unauthenticated, true)
    :ok
  end

  test "Trail Log mounts with full chrome and dummy stats", %{conn: conn} do
    {:ok, view, html} = live(conn, "/squatch")

    for markup <- [html, render(view)] do
      assert markup =~ "SQUATCHMAIL"
      assert markup =~ "Trail Log"
      assert markup =~ "Tracking live"
      assert markup =~ "Sightings"
      assert markup =~ "Delivery rate"
      assert markup =~ "The forest is quiet"
    end
  end

  test "Sighting inspector stub mounts with the given public_id", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/squatch/sightings/em_abc123")

    assert html =~ "em_abc123"
    assert html =~ "unconfirmed"
  end

  test "Suppressions (Do-Not-Disturb) stub mounts", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/squatch/suppressions")

    assert html =~ "Do-Not-Disturb"
    assert html =~ "respects boundaries"
  end

  test "Base Camp stub mounts", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/squatch/base-camp")

    assert html =~ "Base Camp"
    assert html =~ "Connect your SES credentials"
  end

  test "sidebar nav renders all six sections with the current page marked active", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/squatch")

    assert html =~ "Trail Log"
    assert html =~ "Sightings"
    assert html =~ "Bounces"
    assert html =~ "Complaints"
    assert html =~ "Do-Not-Disturb"
    assert html =~ "Base Camp"
    assert html =~ "sq-nav__item--active"
  end
end
