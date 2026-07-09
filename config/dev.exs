import Config

# `SquatchMailDev.Repo` is defined by dev.exs (the `mix dev` preview server),
# not compiled from lib/ — it exists only while that script runs, and its
# connection settings live there too (config for :squatch_mail_dev can't go
# here: it isn't a real OTP application, so Mix would warn at boot). `mix
# ecto.*` tasks can't see the repo; dev.exs creates and migrates the
# database itself at boot.
config :squatch_mail,
  repo: SquatchMailDev.Repo,
  otp_app: :squatch_mail,
  # Dev is expected to run locally with no host auth pipeline configured;
  # opt in to layer (c)'s open-access default explicitly rather than relying
  # on it being unset. See `SquatchMail.Web.Router` for the full auth model.
  allow_unauthenticated: true

config :logger, :default_formatter, colors: [enabled: true]

config :swoosh, :api_client, Swoosh.ApiClient.Finch
config :swoosh, Swoosh.ApiClient.Finch, finch_name: SquatchMail.Finch
