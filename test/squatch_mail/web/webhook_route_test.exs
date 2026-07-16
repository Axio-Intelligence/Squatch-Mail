defmodule SquatchMail.Web.WebhookRouteTest do
  @moduledoc """
  Confirms the router macro wires `POST <path>/webhooks/sns/:token` to
  `SquatchMail.Web.WebhookController`, with the right shape (method, path,
  `:token` param) and CSRF skipped. This only asserts the route shape — the
  controller's actual SNS handling/signature verification (including its own
  404-for-unknown-token behavior) is a different agent's territory; see
  `auth_test.exs` for the "not auth-gated" assertion.

  These tests call `SquatchMail.Test.WebEndpoint.Router` directly via
  `Plug.Test.conn/3` (bypassing the endpoint's `render_errors` pipeline,
  which catches `Phoenix.Router.NoRouteError` and turns it into an ordinary
  404 response) so a genuinely-unrouted path can be told apart from a route
  that exists but whose controller happens to also return 404 for its own
  reasons (e.g. an unrecognized token).
  """

  use SquatchMail.Web.WebCase, async: false

  alias SquatchMail.Test.WebEndpoint.Router

  test "POST routes to the webhook controller with the :token param" do
    conn =
      :post
      |> Plug.Test.conn("/squatch/webhooks/sns/abc123", "{}")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Test.init_test_session(%{})
      |> Router.call(Router.init([]))

    # Whatever the controller's own business logic decides (its 404 for an
    # unrecognized token, its 403 for bad signatures, etc.), the request
    # must have been dispatched to *some* plug rather than raising
    # `NoRouteError` — that's the only thing this test is responsible for.
    assert conn.status in [200, 403, 404, 500]
  end

  test "the route skips CSRF protection", %{conn: conn} do
    # No CSRF token supplied at all; a session-based route would normally
    # raise/403 here via `Plug.CSRFProtection` if it weren't marked
    # `plug_skip_csrf_protection: true`.
    conn =
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post("/squatch/webhooks/sns/abc123", "{}")

    refute conn.status == 403 and conn.resp_body =~ "csrf"
  end

  test "GET is not routed (webhook is POST-only)" do
    conn = Plug.Test.conn(:get, "/squatch/webhooks/sns/abc123")

    assert_raise Phoenix.Router.NoRouteError, fn ->
      Router.call(conn, Router.init([]))
    end
  end

  describe "raw body capture via SquatchMail.SNS.RawBodyPlug" do
    setup do
      # SNS delivers with `Content-Type: text/plain; charset=UTF-8`, which the
      # host endpoint's Plug.Parsers matches no parser for and passes through
      # unread — so `RawBodyPlug` (in SquatchMail's own router pipeline) is
      # what captures the body for these tests, not the endpoint body_reader.
      Application.put_env(:squatch_mail, :verify_sns_signatures, false)
      on_exit(fn -> Application.delete_env(:squatch_mail, :verify_sns_signatures) end)
      :ok
    end

    test "captures the exact text/plain bytes SNS sends, so the Type is recognized", %{conn: conn} do
      # Whitespace is deliberate: if anything re-encoded this (e.g. the
      # controller's `Jason.encode!(conn.params)` fallback), the byte-for-byte
      # whitespace would be lost. Proving this exact binary survives proves the
      # real raw bytes were used — the bug was that for text/plain the body was
      # never read at all, so `conn.params` held only the path params.
      raw_payload = ~s({  "Type" : "UnsubscribeConfirmation" ,"TopicArn":"arn:x"  })

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "text/plain; charset=UTF-8")
        |> post("/squatch/webhooks/sns/abc123", raw_payload)

      assert conn.assigns[:raw_body] == raw_payload
    end

    test "a text/plain Notification is ingested end-to-end (200), not treated as an unknown type",
         %{conn: conn} do
      source = SquatchMail.Tracker.get_or_create_source()

      # A real SNS Notification envelope, delivered as text/plain — the exact
      # shape that used to fall through to `{:unsupported_message_type, nil}`
      # and 500 because the body was never read.
      payload =
        Jason.encode!(%{
          "Type" => "Notification",
          "MessageId" => Ecto.UUID.generate(),
          "TopicArn" => "arn:aws:sns:us-east-1:123456789012:squatch-mail-events",
          "Message" =>
            Jason.encode!(%{"eventType" => "Send", "mail" => %{"messageId" => "msg-abc"}}),
          "Timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "SignatureVersion" => "1",
          "Signature" => "unused",
          "SigningCertURL" => "https://sns.us-east-1.amazonaws.com/cert.pem"
        })

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "text/plain; charset=UTF-8")
        |> post("/squatch/webhooks/sns/#{source.webhook_token}", payload)

      assert conn.assigns[:raw_body] == payload
      assert conn.status == 200
    end

    test "an already-captured raw body (host body_reader path) is left untouched", %{conn: conn} do
      # application/json IS matched by Plug.Parsers, so the endpoint's
      # CacheBodyReader captures the body; RawBodyPlug must then stand down and
      # preserve those exact bytes rather than re-reading an emptied body.
      raw_payload = ~s({  "Type" : "Notification" ,"foo":"bar"  })

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/squatch/webhooks/sns/abc123", raw_payload)

      assert conn.assigns[:raw_body] == raw_payload
    end

    test "non-webhook routes never run RawBodyPlug", %{conn: conn} do
      Application.put_env(:squatch_mail, :allow_unauthenticated, true)
      Application.delete_env(:squatch_mail, :basic_auth)

      conn = get(conn, "/squatch")

      # RawBodyPlug is mounted only on the webhook route's pipeline; every
      # other route (including the rest of the dashboard) should see no
      # :raw_body assign at all.
      refute Map.has_key?(conn.assigns, :raw_body)
    end
  end
end
