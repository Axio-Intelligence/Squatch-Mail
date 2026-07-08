defmodule SquatchMail.Test.WebEndpoint do
  @moduledoc """
  A minimal Phoenix endpoint + router used only by
  `test/squatch_mail/web/*_test.exs` to exercise `SquatchMail.Web.Router`'s
  macro, the asset plug, and the auth layers via `Phoenix.ConnTest` /
  `Phoenix.LiveViewTest`.

  This is deliberately separate from `SquatchMail.DataCase` /
  `SquatchMail.Test.Repo` (the data layer's test support) — the web layer's
  tests don't need a database, only a router to mount the dashboard in.
  """

  defmodule Router do
    @moduledoc false
    use Phoenix.Router
    import Phoenix.Controller
    import SquatchMail.Web.Router

    pipeline :browser do
      plug :accepts, ["html"]
      plug :fetch_session
      plug :fetch_flash
      plug :protect_from_forgery
    end

    scope "/" do
      pipe_through :browser

      # Open-access mount: exercises whichever of layer (b)/(c) applies
      # based on runtime config (see auth_test.exs), same as a host that
      # hasn't wired up its own pipeline.
      squatch_mail_dashboard("/squatch")
    end

    scope "/host-authed" do
      pipe_through :browser

      # Mirrors layer (a): a host `on_mount` is supplied, so layers (b)/(c)
      # must stand down regardless of their configuration. `:as` must be
      # distinct from the default `:squatch_mail_dashboard` used by the "/"
      # mount above — `live_session` names are unique per router module, not
      # per scope (see `SquatchMail.Web.Router`'s moduledoc note on mounting
      # more than once).
      squatch_mail_dashboard("/dash",
        as: :squatch_mail_host_authed,
        on_mount: [SquatchMail.Test.HostOnMount]
      )
    end
  end

  use Phoenix.Endpoint, otp_app: :squatch_mail

  @session_options [
    store: :cookie,
    key: "_squatch_mail_test_key",
    signing_salt: "squatch_mail_test_signing",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.Session, @session_options

  # body_reader wired the same way hosts are documented to wire it in their
  # own endpoint (see SquatchMail.Web.Router's "Webhook raw body" section):
  # path-conditional, so only the SNS webhook route pays for raw-body
  # caching. This lets webhook_route_test.exs prove the reference wiring
  # actually preserves bytes end-to-end, not just that the route dispatches.
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    body_reader: {SquatchMail.Test.CacheBodyReader, :read_body, []}

  plug Plug.MethodOverride
  plug Plug.Head
  plug Router
end

defmodule SquatchMail.Test.CacheBodyReader do
  @moduledoc """
  Test-support copy of the path-conditional `body_reader` documented on
  `SquatchMail.Web.Router` ("Webhook raw body") as required host-endpoint
  wiring — exercised here so `webhook_route_test.exs` can assert the
  documented pattern actually preserves raw bytes to
  `SquatchMail.SNS.RawBodyReader`, not just that routing works.
  """

  def read_body(conn, opts) do
    if match?(["squatch", "webhooks", "sns", _token], conn.path_info) do
      SquatchMail.SNS.RawBodyReader.read_body(conn, opts)
    else
      Plug.Conn.read_body(conn, opts)
    end
  end
end

defmodule SquatchMail.Test.HostOnMount do
  @moduledoc """
  A stand-in for a host application's own `on_mount` auth hook, used to
  exercise layer (a) of `SquatchMail.Web.Router`'s security model in tests.
  """
  def on_mount(:default, _params, _session, socket), do: {:cont, socket}
end

defmodule SquatchMail.Test.ErrorHTML do
  @moduledoc """
  Renders error pages for `SquatchMail.Test.WebEndpoint` (e.g. an
  unhandled exception surfacing as a 500) so test failures show the real
  underlying error instead of a `no "500" html template defined` crash
  masking it.
  """
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
