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
  database: "squatch_mail_dev"

config :logger, :default_formatter, colors: [enabled: true]

config :swoosh, :api_client, Swoosh.ApiClient.Finch
config :swoosh, Swoosh.ApiClient.Finch, finch_name: SquatchMail.Finch
