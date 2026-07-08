import Config

# Bundles the dashboard's self-contained JS (its own copies of `phoenix` +
# `phoenix_live_view`, so host apps don't need to expose their own LiveView
# JS to our pages) into `priv/static/squatch_mail.js`. Run via
# `mix assets.build`; the CSS half of that alias needs no build step since
# `assets/css/squatch_mail.css` is hand-written and copied as-is — see the
# `assets.build` alias in mix.exs.
#
# `:esbuild` is a dev-only dependency (it's a build tool, not something a
# host app or the compiled hex package needs at runtime — the built
# priv/static/squatch_mail.js ships pre-bundled), so this config is scoped to
# :dev to avoid "you have configured :esbuild but it's not available"
# warnings in :test and in host applications.
if config_env() == :dev do
  config :esbuild,
    version: "0.21.5",
    squatch_mail: [
      args:
        ~w(js/squatch_mail.js --bundle --target=es2017 --outdir=../priv/static --out-extension:.js=.js),
      cd: Path.expand("../assets", __DIR__),
      env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
    ]
end

if Mix.env() in [:dev, :test] do
  import_config "#{config_env()}.exs"
end
