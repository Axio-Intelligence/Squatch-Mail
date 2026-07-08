defmodule SquatchMail.Web.TrailLogLiveTest do
  @moduledoc """
  End-to-end LiveView tests for the Trail Log.

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

  test "mounts with the empty state when there are no emails", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/squatch")

    assert html =~ "Trail Log"
    assert html =~ "Tracking live"
    assert html =~ "The forest is quiet"
  end

  test "renders sent emails in the activity table", %{conn: conn} do
    {:ok, email} =
      Tracker.record_email(%{
        from_email: "camp@example.com",
        subject: "Base Camp coordinates",
        status: "delivered",
        recipients: [%{kind: "to", address: "hiker@example.com"}]
      })

    {:ok, _view, html} = live(conn, "/squatch")

    assert html =~ email.public_id
    assert html =~ "hiker@example.com"
    assert html =~ "Base Camp coordinates"
    assert html =~ "sq-badge--delivered"
  end

  test "the engagement column shows real open/click counts from Tracker.engagement_counts/1", %{
    conn: conn
  } do
    {:ok, email} =
      Tracker.record_email(%{
        from_email: "camp@example.com",
        subject: "Engaged sighting",
        status: "clicked",
        message_id: "msg-#{System.unique_integer([:positive])}",
        recipients: [%{kind: "to", address: "hiker@example.com"}]
      })

    {:ok, _open} =
      Tracker.record_event(%{
        message_id: email.message_id,
        event_type: "open",
        recipient: "hiker@example.com",
        occurred_at: DateTime.utc_now()
      })

    {:ok, _click1} =
      Tracker.record_event(%{
        message_id: email.message_id,
        event_type: "click",
        recipient: "hiker@example.com",
        url: "https://example.com/a",
        occurred_at: DateTime.utc_now()
      })

    {:ok, _click2} =
      Tracker.record_event(%{
        message_id: email.message_id,
        event_type: "click",
        recipient: "hiker@example.com",
        url: "https://example.com/b",
        occurred_at: DateTime.utc_now()
      })

    {:ok, _view, html} = live(conn, "/squatch")

    assert html =~ "◉ 1"
    assert html =~ "↗ 2"
  end

  test "the stat strip reflects Tracker.stats/1 rates", %{conn: conn} do
    {:ok, _email} =
      Tracker.record_email(%{
        from_email: "camp@example.com",
        subject: "Trail map",
        status: "delivered",
        recipients: [%{kind: "to", address: "hiker@example.com"}]
      })

    {:ok, _view, html} = live(conn, "/squatch")

    assert html =~ "Sightings"
    assert html =~ "Delivery rate"
    assert html =~ "100.0%"
  end

  test "filtering by status patches the URL and narrows the table", %{conn: conn} do
    {:ok, delivered} =
      Tracker.record_email(%{
        from_email: "a@example.com",
        subject: "Delivered one",
        status: "delivered",
        recipients: [%{kind: "to", address: "one@example.com"}]
      })

    {:ok, bounced} =
      Tracker.record_email(%{
        from_email: "a@example.com",
        subject: "Bounced one",
        status: "bounced",
        recipients: [%{kind: "to", address: "two@example.com"}]
      })

    {:ok, view, _html} = live(conn, "/squatch")

    html =
      view
      |> element("#sq-trail-log-status")
      |> render_change(%{"status" => "bounced"})

    assert html =~ bounced.public_id
    refute html =~ delivered.public_id
    assert_patch(view, "/squatch?status=bounced")
  end

  test "searching narrows the table by subject/recipient", %{conn: conn} do
    {:ok, match} =
      Tracker.record_email(%{
        from_email: "a@example.com",
        subject: "Squatch sighting near ridge",
        status: "sent",
        recipients: [%{kind: "to", address: "ranger@example.com"}]
      })

    {:ok, other} =
      Tracker.record_email(%{
        from_email: "a@example.com",
        subject: "Unrelated",
        status: "sent",
        recipients: [%{kind: "to", address: "someone@example.com"}]
      })

    {:ok, view, _html} = live(conn, "/squatch")

    html =
      view
      |> element("#sq-trail-log-search")
      |> render_change(%{"q" => "ridge"})

    assert html =~ match.public_id
    refute html =~ other.public_id
  end

  test "clicking a row navigates to the Sighting inspector with a back query", %{conn: conn} do
    {:ok, email} =
      Tracker.record_email(%{
        from_email: "a@example.com",
        subject: "Click me",
        status: "sent",
        recipients: [%{kind: "to", address: "click@example.com"}]
      })

    {:ok, view, _html} = live(conn, "/squatch?status=sent")

    {:error, {:live_redirect, %{to: to}}} =
      view
      |> element("tr[phx-value-public_id='#{email.public_id}']")
      |> render_click()

    assert to =~ "/squatch/sightings/#{email.public_id}"
    assert to =~ "back="
  end

  test "a squatch_mail email:recorded telemetry event triggers a debounced refresh", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, "/squatch")
    assert html =~ "The forest is quiet"

    {:ok, email} =
      Tracker.record_email(%{
        from_email: "a@example.com",
        subject: "Fresh sighting",
        status: "sent",
        recipients: [%{kind: "to", address: "fresh@example.com"}]
      })

    :telemetry.execute([:squatch_mail, :email, :recorded], %{count: 1}, %{email: email})

    # The handler forwards to the LiveView process, which debounces via
    # Process.send_after/3 before reloading — poll briefly for the render to
    # pick up the new row rather than asserting instantly.
    assert wait_until(fn -> render(view) =~ email.public_id end)
  end

  defp wait_until(fun, attempts \\ 20) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(50)
        wait_until(fun, attempts - 1)
    end
  end
end
