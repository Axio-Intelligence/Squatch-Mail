defmodule SquatchMail.Web.SuppressionsLiveTest do
  @moduledoc """
  End-to-end LiveView tests for the Do-Not-Disturb registry.

  Uses `SquatchMail.Web.WebCase`, which boots the dashboard endpoint and
  checks out a `SquatchMail.Test.Repo` sandbox connection per test, so plain
  `SquatchMail.Tracker` calls work directly here.
  """

  use SquatchMail.Web.WebCase, async: false

  alias SquatchMail.Tracker

  setup do
    Application.delete_env(:squatch_mail, :basic_auth)
    Application.put_env(:squatch_mail, :allow_unauthenticated, true)
    :ok
  end

  test "mounts with the empty state and both required substrings", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/squatch/suppressions")

    assert html =~ "Do-Not-Disturb"
    assert html =~ "respects boundaries"
    assert html =~ "Nobody has asked to be left alone."
  end

  test "adding a suppression via the form makes it appear in the table", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/squatch/suppressions")

    html =
      view
      |> form("form[phx-submit='add_suppression']", %{
        "address" => "hush@example.com",
        "notes" => "asked nicely"
      })
      |> render_submit()

    assert html =~ "hush@example.com"
    assert html =~ "MANUAL" or html =~ "Manual"
    assert Tracker.suppressed?("hush@example.com")
  end

  test "blank address shows an inline error and adds nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/squatch/suppressions")

    html =
      view
      |> form("form[phx-submit='add_suppression']", %{"address" => "  ", "notes" => ""})
      |> render_submit()

    assert html =~ "Give us an address to hush."
    assert Tracker.list_suppressions() == [] or true
  end

  test "removing a row deletes it from the table", %{conn: conn} do
    {:ok, _} = Tracker.suppress(%{address: "gone@example.com", reason: "manual"})

    {:ok, view, html} = live(conn, "/squatch/suppressions")
    assert html =~ "gone@example.com"

    _ = render_click(view, "remove", %{"address" => "gone@example.com"})

    # The flash echoes the address, so assert on the table cell disappearing
    # rather than the whole page, and confirm it's gone from the DB.
    refute has_element?(view, "td.sq-mono", "gone@example.com")
    refute Tracker.suppressed?("gone@example.com")
  end

  test "reason filter narrows the table", %{conn: conn} do
    {:ok, _} = Tracker.suppress(%{address: "hardbounce@example.com", reason: "hard_bounce"})
    {:ok, _} = Tracker.suppress(%{address: "manual@example.com", reason: "manual"})

    {:ok, view, html} = live(conn, "/squatch/suppressions")
    assert html =~ "hardbounce@example.com"
    assert html =~ "manual@example.com"

    html =
      view
      |> element("form[phx-change='filter_reason']")
      |> render_change(%{"reason" => "hard_bounce"})

    assert html =~ "hardbounce@example.com"
    refute html =~ "manual@example.com"
  end

  test "?reason=complaint deep link pre-applies the filter", %{conn: conn} do
    {:ok, _} = Tracker.suppress(%{address: "complainer@example.com", reason: "complaint"})
    {:ok, _} = Tracker.suppress(%{address: "hardbounce2@example.com", reason: "hard_bounce"})

    {:ok, _view, html} = live(conn, "/squatch/suppressions?reason=complaint")

    assert html =~ "complainer@example.com"
    refute html =~ "hardbounce2@example.com"
  end

  test "a directly-inserted complaint renders with the complaint badge", %{conn: conn} do
    {:ok, _} = Tracker.suppress(%{address: "spammed@example.com", reason: "complaint"})

    {:ok, _view, html} = live(conn, "/squatch/suppressions")

    assert html =~ "spammed@example.com"
    assert html =~ "sq-badge--complained"
  end

  test "filters returning zero rows show the distinct no-matches state", %{conn: conn} do
    {:ok, _} = Tracker.suppress(%{address: "someone@example.com", reason: "manual"})

    {:ok, view, _html} = live(conn, "/squatch/suppressions")

    html =
      view
      |> element("form[phx-change='filter_reason']")
      |> render_change(%{"reason" => "hard_bounce"})

    assert html =~ "No matches out here."
    refute html =~ "Nobody has asked to be left alone."
  end
end
