import Config

config :squatch_mail,
  repo: SquatchMail.Test.Repo,
  otp_app: :squatch_mail,
  ecto_repos: [SquatchMail.Test.Repo]

config :squatch_mail, SquatchMail.Test.Repo,
  username: System.get_env("PGUSER", System.get_env("USER", "postgres")),
  password: System.get_env("PGPASSWORD", ""),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: "squatch_mail_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  log: false

# Same physical database as SquatchMail.Test.Repo above, but a plain
# (non-sandbox) pool — see SquatchMail.Test.UnsandboxedRepo's moduledoc for
# why this exists (Ecto.Migrator needs a connection that isn't subject to
# per-test sandbox ownership, without disturbing the sandboxed repo used by
# every other test).
config :squatch_mail, SquatchMail.Test.UnsandboxedRepo,
  username: System.get_env("PGUSER", System.get_env("USER", "postgres")),
  password: System.get_env("PGPASSWORD", ""),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: "squatch_mail_test",
  pool_size: 2,
  log: false

config :logger, level: :warning

# Endpoint for the web-layer's own test support (test/support/web_endpoint.ex),
# used by test/squatch_mail/web/*_test.exs. Separate from the data layer's
# `SquatchMail.Test.Repo` config above — these tests need a router, not a
# database.
config :squatch_mail, SquatchMail.Test.WebEndpoint,
  live_view: [signing_salt: "squatch_mail_test_salt"],
  secret_key_base: String.duplicate("a", 64),
  pubsub_server: SquatchMail.Test.PubSub,
  server: false,
  check_origin: false,
  render_errors: [formats: [html: SquatchMail.Test.ErrorHTML], layout: false]

# Swoosh is only present here as an optional/observed dependency (see
# CLAUDE.md); avoid pulling in hackney just to satisfy its Application start.
config :swoosh, :api_client, Swoosh.ApiClient.Finch
config :swoosh, Swoosh.ApiClient.Finch, finch_name: SquatchMail.Finch
