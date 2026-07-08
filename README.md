# SquatchMail

A self-hosted Amazon SES email dashboard for Phoenix apps, shipped as an
embeddable Hex package. Add the dependency, run a migration, mount a route —
get a LiveView email-observability dashboard backed by your own database.

See `RESEARCH.md`, `FEATURES.md`, and `DESIGN.md` for the full architecture
and design rationale.

## Installation

### With igniter (recommended)

If your project already uses [igniter](https://hexdocs.pm/igniter), add
SquatchMail and run its installer in one step:

```bash
mix igniter.install squatch_mail
```

This adds `:squatch_mail` to `mix.exs`, configures it in `config.exs`,
generates the migration that creates its tables, and mounts the dashboard in
your router at `/squatch`.

### Manual installation

If you'd rather not use igniter, or want full control over each step:

1. **Add the dependency** to `mix.exs`:

   ```elixir
   def deps do
     [
       {:squatch_mail, "~> 0.1"}
     ]
   end
   ```

   Then run `mix deps.get`.

2. **Configure SquatchMail** in `config/config.exs`:

   ```elixir
   config :squatch_mail,
     repo: MyApp.Repo,
     otp_app: :my_app,
     prefix: "squatch_mail"
   ```

   `:repo` is required — it's the `Ecto.Repo` SquatchMail uses to read and
   write its own tables, which live in their own `squatch_mail` Postgres
   schema so they never collide with your application's tables. See
   `SquatchMail.Config` for all supported options.

3. **Generate and run the migration**. Create a new migration in your host
   app (`mix ecto.gen.migration add_squatch_mail`) with:

   ```elixir
   defmodule MyApp.Repo.Migrations.AddSquatchMail do
     use Ecto.Migration

     def up, do: SquatchMail.Migrations.up(version: 1)
     def down, do: SquatchMail.Migrations.down(version: 1)
   end
   ```

   Then run `mix ecto.migrate`. Future SquatchMail releases that add tables
   or columns will ship as new versions behind this same API — bump the
   `version:` number and re-run `mix ecto.migrate` to upgrade.

4. **Mount the dashboard** in your router:

   ```elixir
   defmodule MyAppWeb.Router do
     use MyAppWeb, :router
     import SquatchMail.Router

     scope "/" do
       pipe_through :browser

       squatch_mail_dashboard "/squatch"
     end
   end
   ```

   Visit `/squatch` to see the dashboard. No other code changes are
   required — SquatchMail observes mail sent through Swoosh automatically
   via telemetry.

## License

MIT
