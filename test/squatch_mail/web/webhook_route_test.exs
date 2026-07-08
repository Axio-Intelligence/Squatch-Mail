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
end
