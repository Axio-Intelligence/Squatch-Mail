# Development preview server for SquatchMail.
#
# Boots a minimal Phoenix endpoint with the SquatchMail dashboard mounted at
# /squatch, backed by a dev Postgres database (`squatch_mail_dev`, created and
# migrated automatically at boot) and Swoosh's local adapter.
#
# Usage:
#
#     mix dev
#
# or, to also get an IEx shell for sending test emails through the capture
# pipeline:
#
#     iex -S mix dev
#     iex> import Swoosh.Email
#     iex> new(to: "sasquatch@example.com", from: "ranger@example.com",
#     ...>   subject: "hello", text_body: "hi") |> SquatchMailDev.Mailer.deliver()

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

# The repo the whole preview runs on. config/dev.exs points
# `:squatch_mail, :repo` here; the module itself can't live in lib/ because
# the library must never ship a repo — hosts always bring their own.
Application.put_env(:squatch_mail_dev, SquatchMailDev.Repo,
  username: System.get_env("PGUSER", System.get_env("USER", "postgres")),
  password: System.get_env("PGPASSWORD", ""),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: "squatch_mail_dev"
)

defmodule SquatchMailDev.Repo do
  use Ecto.Repo, otp_app: :squatch_mail_dev, adapter: Ecto.Adapters.Postgres
end

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
        <p>The dashboard is mounted at <a href="/squatch">/squatch</a>.</p>
      </body>
    </html>
    """)
  end
end

defmodule SquatchMailDev.CacheBodyReader do
  @moduledoc """
  Reference implementation of the host-side `body_reader` every application
  mounting `squatch_mail_dashboard` must add to their own endpoint — see
  `SquatchMail.Web.Router`'s moduledoc ("Webhook raw body") for why this
  can't be done inside the dashboard's router macro. `Plug.Parsers`'
  `:body_reader` is endpoint-wide, not per-route, so the reader itself must
  check the path: only the SNS webhook route needs raw bytes cached via
  `SquatchMail.SNS.RawBodyReader`; every other request (including the rest
  of the dashboard) falls through to the plain, uncached reader.
  """

  def read_body(conn, opts) do
    if match?(["squatch", "webhooks", "sns", _token], conn.path_info) do
      SquatchMail.SNS.RawBodyReader.read_body(conn, opts)
    else
      Plug.Conn.read_body(conn, opts)
    end
  end
end

defmodule SquatchMailDev.Router do
  use Phoenix.Router
  import Phoenix.Controller
  import SquatchMail.Web.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :put_secure_browser_headers
    plug :protect_from_forgery
  end

  scope "/" do
    pipe_through :browser

    get "/", SquatchMailDev.PageController, :index

    # Open access in dev: no `:on_mount` given and no `:basic_auth`
    # configured, so `SquatchMail.Web.Plugs.Auth` falls through to layer (c)
    # — allowed here because config/dev.exs sets `allow_unauthenticated: true`.
    squatch_mail_dashboard("/squatch")
  end
end

defmodule SquatchMailDev.Endpoint do
  use Phoenix.Endpoint, otp_app: :squatch_mail_dev

  socket "/live", Phoenix.LiveView.Socket

  plug Plug.Static, at: "/", from: :squatch_mail, gzip: false

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # `body_reader` is endpoint-wide (Plug.Parsers has no per-route scoping),
  # so the reader itself must decide, per request, whether to cache raw
  # bytes — SquatchMailDev.CacheBodyReader below only does so for the SNS
  # webhook path and otherwise falls through to the plain reader. See
  # `SquatchMail.Web.Router`'s moduledoc ("Webhook raw body") for why this
  # can't be handled inside the dashboard's own router macro: by the time a
  # router runs, an endpoint's Plug.Parsers has already consumed the body.
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    body_reader: {SquatchMailDev.CacheBodyReader, :read_body, []}

  plug Plug.MethodOverride
  plug Plug.Head

  plug Plug.Session,
    store: :cookie,
    key: "_squatch_mail_dev_key",
    signing_salt: "squatch_mail_dev_signing"

  plug SquatchMailDev.Router
end

# Create the dev database if it doesn't exist yet ({:error, :already_up} on
# every boot after the first).
case SquatchMailDev.Repo.__adapter__().storage_up(SquatchMailDev.Repo.config()) do
  :ok -> IO.puts("Created database squatch_mail_dev")
  {:error, :already_up} -> :ok
  {:error, reason} -> raise "could not create squatch_mail_dev: #{inspect(reason)}"
end

children = [
  SquatchMailDev.Repo,
  {Phoenix.PubSub, name: SquatchMailDev.PubSub},
  SquatchMailDev.Endpoint
]

{:ok, _pid} =
  Supervisor.start_link(children, strategy: :one_for_one, name: SquatchMailDev.Supervisor)

# Bring the schema up to date on every boot. This is the same versioned
# migration a host app would generate (see SquatchMail.Migrations); running
# it through Ecto.Migrator is idempotent, so already-applied versions are
# skipped.
Ecto.Migrator.run(SquatchMailDev.Repo, "priv/repo/migrations", :up, all: true)

IO.puts("SquatchMail dev preview running at http://localhost:4000")

Process.sleep(:infinity)
