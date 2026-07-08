# Development preview server for SquatchMail.
#
# Boots a minimal Phoenix endpoint with the (future) SquatchMail dashboard
# mounted, backed by a dev Postgres database and Swoosh's local adapter.
#
# Usage:
#
#     mix dev
#
# TODO: once the dashboard router macro exists, mount it here, e.g.:
#
#     scope "/" do
#       pipe_through :browser
#       squatch_mail_dashboard "/squatch"
#     end

Application.put_env(:squatch_mail_dev, SquatchMailDev.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: true,
  live_view: [signing_salt: "squatch_mail_dev_salt"],
  secret_key_base: String.duplicate("a", 64),
  pubsub_server: SquatchMailDev.PubSub,
  check_origin: false
)

Application.put_env(:swoosh, :api_client, false)

defmodule SquatchMailDev.Mailer do
  use Swoosh.Mailer, otp_app: :squatch_mail_dev
end

Application.put_env(:squatch_mail_dev, SquatchMailDev.Mailer, adapter: Swoosh.Adapters.Local)

defmodule SquatchMailDev.ErrorHTML do
  @moduledoc false
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule SquatchMailDev.PageController do
  use Phoenix.Controller,
    formats: [:html],
    layouts: []

  def index(conn, _params) do
    html(conn, """
    <!doctype html>
    <html>
      <head><title>SquatchMail dev</title></head>
      <body>
        <h1>SquatchMail dev preview</h1>
        <p>The dashboard isn't mounted yet — this is a placeholder page.</p>
        <p>See the TODO at the top of <code>dev.exs</code>.</p>
      </body>
    </html>
    """)
  end
end

defmodule SquatchMailDev.Router do
  use Phoenix.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :put_secure_browser_headers
  end

  scope "/" do
    pipe_through :browser

    get "/", SquatchMailDev.PageController, :index

    # TODO: mount `squatch_mail_dashboard "/squatch"` here once it exists.
  end
end

defmodule SquatchMailDev.Endpoint do
  use Phoenix.Endpoint, otp_app: :squatch_mail_dev

  socket "/live", Phoenix.LiveView.Socket

  plug Plug.Static, at: "/", from: :squatch_mail, gzip: false

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head

  plug Plug.Session,
    store: :cookie,
    key: "_squatch_mail_dev_key",
    signing_salt: "squatch_mail_dev_signing"

  plug SquatchMailDev.Router
end

children = [
  {Phoenix.PubSub, name: SquatchMailDev.PubSub},
  SquatchMailDev.Endpoint
]

{:ok, _pid} =
  Supervisor.start_link(children, strategy: :one_for_one, name: SquatchMailDev.Supervisor)

IO.puts("SquatchMail dev preview running at http://localhost:4000")

Process.sleep(:infinity)
