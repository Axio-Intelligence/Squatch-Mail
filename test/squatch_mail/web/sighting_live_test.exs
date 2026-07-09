defmodule SquatchMail.Web.SightingLiveTest do
  @moduledoc """
  End-to-end LiveView tests for the Sighting inspector, including the
  Preview tab's iframe sandboxing — the security-sensitive part of this
  page, since `html_body` is untrusted third-party content.
  """

  use SquatchMail.Web.WebCase, async: false

  alias SquatchMail.Tracker

  setup do
    Application.delete_env(:squatch_mail, :basic_auth)
    Application.put_env(:squatch_mail, :allow_unauthenticated, true)
    :ok
  end

  test "shows the unconfirmed empty state for an unknown public_id", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/squatch/sightings/em_doesnotexist")

    assert html =~ "unconfirmed"
    assert html =~ "Probably a bear"
  end

  test "renders the summary card with status, recipients, and subject", %{conn: conn} do
    {:ok, email} =
      Tracker.record_email(%{
        from_email: "camp@example.com",
        subject: "Sighting report",
        status: "delivered",
        html_body: "<p>Hello</p>",
        text_body: "Hello",
        recipients: [%{kind: "to", address: "ranger@example.com"}]
      })

    {:ok, _view, html} = live(conn, "/squatch/sightings/#{email.public_id}")

    assert html =~ "Sighting report"
    assert html =~ "ranger@example.com"
    assert html =~ "camp@example.com"
    assert html =~ "sq-badge--delivered"
  end

  test "the Preview tab renders html_body inside a sandboxed iframe, never inline", %{conn: conn} do
    malicious_html = ~s(<p>hi</p><script>window.pwned = true;</script>)

    {:ok, email} =
      Tracker.record_email(%{
        from_email: "camp@example.com",
        subject: "Untrusted body",
        status: "delivered",
        html_body: malicious_html,
        recipients: [%{kind: "to", address: "ranger@example.com"}]
      })

    {:ok, _view, html} = live(conn, "/squatch/sightings/#{email.public_id}")

    # The iframe must exist, be sandboxed, and carry NO allow-scripts token.
    assert [iframe_tag] = Regex.run(~r/<iframe[^>]*>/, html)
    assert iframe_tag =~ ~s(sandbox="allow-same-origin")
    refute iframe_tag =~ "allow-scripts"

    # The raw <script> tag must appear ONLY inside the escaped srcdoc
    # attribute value (as &lt;script&gt;), never as a literal, executable
    # <script> tag anywhere else in the page markup.
    without_iframe = String.replace(html, iframe_tag, "")
    refute without_iframe =~ "<script>window.pwned"

    assert iframe_tag =~ "&lt;script&gt;" or html =~ "srcdoc="
  end

  test "switching tabs shows Text/Headers/Footprints/Raw content", %{conn: conn} do
    {:ok, email} =
      Tracker.record_email(%{
        from_email: "camp@example.com",
        subject: "Tabbed",
        status: "sent",
        text_body: "Plain text body",
        headers: %{"X-Test" => "yes"},
        recipients: [%{kind: "to", address: "ranger@example.com"}]
      })

    {:ok, view, _html} = live(conn, "/squatch/sightings/#{email.public_id}")

    text_html = view |> element("button[phx-value-tab='text']") |> render_click()
    assert text_html =~ "Plain text body"

    headers_html = view |> element("button[phx-value-tab='headers']") |> render_click()
    assert headers_html =~ "X-Test"

    footprints_html = view |> element("button[phx-value-tab='footprints']") |> render_click()
    assert footprints_html =~ "No footprints yet."

    raw_html = view |> element("button[phx-value-tab='raw']") |> render_click()
    assert raw_html =~ email.public_id
  end

  test "the Footprints tab renders the event timeline with footprint icons", %{conn: conn} do
    {:ok, email} =
      Tracker.record_email(%{
        from_email: "camp@example.com",
        subject: "Has events",
        status: "clicked",
        message_id: "msg-#{System.unique_integer([:positive])}",
        recipients: [%{kind: "to", address: "ranger@example.com"}]
      })

    {:ok, _event} =
      Tracker.record_event(%{
        message_id: email.message_id,
        event_type: "click",
        recipient: "ranger@example.com",
        url: "https://example.com/trail",
        occurred_at: DateTime.utc_now()
      })

    {:ok, view, _html} = live(conn, "/squatch/sightings/#{email.public_id}")

    html = view |> element("button[phx-value-tab='footprints']") |> render_click()

    assert html =~ "Click"
    assert html =~ "https://example.com/trail"
    assert html =~ "sq-timeline__item"
  end

  test "the back link preserves the Trail Log's filter query string", %{conn: conn} do
    {:ok, email} =
      Tracker.record_email(%{
        from_email: "camp@example.com",
        subject: "Back nav",
        status: "sent",
        recipients: [%{kind: "to", address: "ranger@example.com"}]
      })

    back = URI.encode_query(%{"back" => "?status=sent"})
    {:ok, _view, html} = live(conn, "/squatch/sightings/#{email.public_id}?#{back}")

    assert html =~ "Back to the trail"
    assert html =~ ~s(href="/squatch?status=sent")
  end
end
