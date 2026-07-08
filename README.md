<!-- ASCII sasquatch, because the module names are not allowed to have any fun -->
```
                              _.--""--._
                           .'            `.
                          /    .-""-.      \
                         |    /  ,,  \      |
                         |   |  (OO)  |     |     "It leaves footprints.
                         \    \  ''  /     /        You leave... an
                          `.   `""""'    .'         Ecto migration."
                            `--..____..--'
                          .-'   /  \   `-.
                         /     /    \     \
                        |     |      |     |
                         \     \    /     /
                          `.    `--'    .'
                            `-.______.-'
                             _|      |_
                            (_,       ,_)
```

# SquatchMail

**Big footprint. Tiny bill.**

SquatchMail is a self-hosted Amazon SES email dashboard for Phoenix
applications, shipped as an embeddable Hex package — the ErrorTracker / Oban
Web model, not a Docker Compose stack you have to babysit. Add the
dependency, run one migration, mount one route, and every email your app
sends through SES gets a live activity feed, delivery/open/click tracking,
bounce and complaint handling, and a suppression list, all backed by tables
that live quietly in their own Postgres schema inside your existing database.

No queue to stand up. No Redis. No separate service to deploy, monitor, and
eventually forget about. If your Phoenix app already talks to SES, SquatchMail
is mostly just... there.

## Why "Squatch"

Every email you send is a **Sighting**. Every SES event it generates —
delivered, opened, clicked, bounced, complained about — is a **Footprint**.
The suppression list is the **Do-Not-Disturb Registry**, because some
addresses have asked, politely or via a hard bounce, to be left alone. The
SES connection screen is **Base Camp**. The activity feed is the **Trail
Log**. You are, in effect, running a small cryptozoology research station for
your own outbound mail. We take this exactly as seriously as it deserves and
not one degree more — the code underneath (`Email`, `EmailEvent`,
`Suppression`) is boring on purpose. The bigfoot is a costume the UI wears,
not a religion the codebase practices.

If a Sighting goes quiet in the woods, you'll know within a `COMMENT ON
TABLE`-tracked schema migration.

## What you get

- **Zero-config send observability.** SquatchMail attaches to Swoosh's
  telemetry events (`[:swoosh, :deliver, :stop | :exception]`) at boot and
  captures every send your app makes through its *existing* Swoosh mailer —
  no adapter swap, no proxy, no code changes to your send path. This is the
  thing LaraSend and friends structurally cannot do, because they aren't
  living inside your BEAM node.
- **SES event ingestion.** An SNS-backed webhook route (mounted for you,
  hand-verified signatures, no `ex_aws` dependency) turns delivery, bounce,
  complaint, open, click, reject, and delay notifications into a per-email
  timeline of Footprints, and automatically maintains your suppression list
  (hard bounces and complaints are permanent; soft bounces expire).
- **One-click SES provisioning.** "Connect SES" from Base Camp creates the
  configuration set, SNS topic, HTTPS subscription, and event destination for
  you via `AWS.SESv2`/`AWS.SNS` — the manual afternoon LaraSend asks you to
  spend in the AWS console, done from a button.
- **Identity + DKIM guidance.** List your sending identities, see
  verification and DKIM status, and get copy-paste DNS records (CNAME for
  DKIM, TXT for SPF/DMARC) instead of AWS's own documentation tabs.
  Quota sync, cached for six hours, so Base Camp doesn't hammer `GetAccount`
  on every page load.
- **A real dashboard, not a log tail.** LiveView-native activity feed with
  live updates, per-email inspector (rendered HTML preview, headers, tags,
  Footprint timeline), suppression management, and retention-based pruning —
  all shipped as precompiled, self-contained assets. Your host app's asset
  pipeline never needs to know SquatchMail exists.
- **Your database, your rules.** Every table lives inside its own `squatch_mail`
  Postgres schema (configurable), versioned and migrated the same way
  Oban and ErrorTracker do it — one host-owned migration file that calls
  `SquatchMail.Migrations.up()`, safe to re-run as new versions ship.

See [`FEATURES.md`](FEATURES.md) for the full feature inventory (including
what's *not* built yet) and [`RESEARCH.md`](RESEARCH.md) /
[`DESIGN.md`](DESIGN.md) for the architecture and visual design rationale
behind all of this.

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

     def up, do: SquatchMail.Migrations.up()
     def down, do: SquatchMail.Migrations.down()
   end
   ```

   Then run `mix ecto.migrate`. Future SquatchMail releases that add tables
   or columns ship as new versions behind this same API — `up()`/`down()`
   with no `version:` always resolve to "latest"/"initial", so this file
   never needs editing as SquatchMail evolves.

4. **Mount the dashboard** in your router:

   ```elixir
   defmodule MyAppWeb.Router do
     use MyAppWeb, :router
     import SquatchMail.Web.Router

     scope "/" do
       pipe_through :browser

       squatch_mail_dashboard "/squatch"
     end
   end
   ```

   Visit `/squatch` to see the dashboard. No other code changes are
   required — SquatchMail observes mail sent through Swoosh automatically
   via telemetry.

   **Read the Security section below before you deploy this anywhere but
   your own laptop.** By default, in anything that isn't a bare `mix deps.get`
   sandbox, SquatchMail refuses to serve the dashboard until you've told it
   who's allowed in.

## Security

SquatchMail ships three layers of dashboard access control, checked in order.
Exactly one applies to any given request to a dashboard page (Trail Log,
Sightings, Suppressions, Base Camp). The inbound SNS webhook route is never
covered by any of them — it authenticates itself independently.

**a) Host-owned authentication (recommended).** Mount
`squatch_mail_dashboard` inside your own authenticated pipeline and pass your
own `on_mount` hooks, exactly like Oban Web or Phoenix LiveDashboard:

```elixir
scope "/" do
  pipe_through [:browser, :require_admin_user]
  squatch_mail_dashboard "/squatch", on_mount: [MyAppWeb.AdminAuth]
end
```

This is the only layer that can express real authorization — roles,
per-user scoping, SSO. Layers (b) and (c) are a safety net for hosts that
mount the dashboard without wiring up their own auth, not a substitute for
doing so.

**b) Built-in fallback: HTTP Basic Auth.** If you configure

```elixir
config :squatch_mail,
  basic_auth: [username: "squatch", password: System.fetch_env!("SQUATCH_MAIL_PASSWORD")]
```

every dashboard route is protected by `Plug.BasicAuth` with those
credentials. Meant for small deployments that want *something* stronger than
wide open without standing up a real admin pipeline.

**c) Safe default: refuse.** If neither (a) nor (b) applies, SquatchMail
checks `Application.get_env(:squatch_mail, :allow_unauthenticated, false)` —
a runtime check (not `Mix.env()`, which doesn't exist in a release, and would
silently disable this exact safeguard in production). When it's `false`,
dashboard routes render a plain-language refusal page instead of your data,
explaining how to configure (a) or (b). Set it to `true` explicitly if you're
running locally and want the dashboard open with no fuss:

```elixir
config :squatch_mail, allow_unauthenticated: true
```

**The SNS webhook.** `POST .../webhooks/sns/:token` is a machine-to-machine
route, not a browser session, so none of the above applies to it. It's
protected instead by a random per-source `webhook_token` in the URL path
(defense in depth) plus SNS message signature verification performed inside
the request handler — a payload with a forged or missing signature is
rejected before it can touch your data, regardless of whether the token in
the URL is correct.

**Credentials at rest.** AWS credentials for SES/SNS provisioning are either
read from the environment (`credentials_mode: "ambient"`, the default — no
keys touch your database) or, if you opt into `credentials_mode: "static"`,
stored as plaintext columns on the `sources` table today. Encrypting
`access_key_id`/`secret_access_key` at rest is a known gap, tracked as a TODO
in `SquatchMail.Source` — prefer ambient credentials (an IAM instance role,
or environment variables injected by your platform) until that lands.

**Found a security issue?** See [`SECURITY.md`](SECURITY.md) for how to
report it.

## Feature parity checklist

Tracking against the [LaraSend](https://larasend.com/) feature inventory
documented in [`FEATURES.md`](FEATURES.md). **P1** = this embeddable library;
**P2** = a future standalone app; **—** = intentionally out of scope for P1.

| Feature | Status | Notes |
|---|---|---|
| Zero-config Swoosh telemetry capture | ✅ Shipped | `SquatchMail.Capture` — LaraSend has no equivalent |
| Versioned migrations (Oban/ErrorTracker pattern) | ✅ Shipped | `SquatchMail.Migrations`, schema-comment version tracking |
| Core schema (emails, recipients, attachments, events, suppressions, webhook logs, source) | ✅ Shipped | `SquatchMail.Tracker` context |
| SES event ingestion (SNS webhook, signature verification, event normalizer) | 🚧 In progress | hand-rolled signature verification, no `ex_aws` |
| Suppression list (hard bounce/complaint permanent, soft bounce expiring) | ✅ Shipped | enforced in `SquatchMail.Tracker` |
| One-click SES provisioning (config set + SNS topic + subscription) | ✅ Shipped | `SquatchMail.SES.provision/2` — LaraSend requires manual console setup |
| SES quota sync (6h cache) | ✅ Shipped | `SquatchMail.SES.sync_quota/1` |
| Identity list + DKIM/verification status + DNS record guidance | ✅ Shipped | `SquatchMail.SES.list_identities/1`, `dns_records_for/1` |
| Live DNS re-check | 🗓 Planned | currently re-queries SES's own verification status; live `:inet_res` lookups are a follow-up |
| Dashboard foundation (router macro, auth, layout, self-contained assets) | 🚧 In progress | `SquatchMail.Web.Router`, three-layer auth model above |
| Activity feed + email inspector + stats | 🗓 Planned | Trail Log, Sighting inspector |
| Suppressions / bounces / complaints / settings pages | 🗓 Planned | Do-Not-Disturb registry, Base Camp |
| Retention pruning (Oban job honoring `retention_days`) | 🚧 In progress | `SquatchMail.Tracker.prune/0` exists; scheduled worker pending |
| Igniter installer + manual install path | ✅ Shipped | `mix igniter.install squatch_mail` |
| Credential encryption at rest (static mode) | 🗓 Planned | see Security section |
| Templates, workspaces, API keys, outbound webhooks, multi-project | — | P2 (standalone app) scope, not P1 |

## Requirements

Elixir 1.15+, Ecto 3.13+, Phoenix LiveView 1.0+, PostgreSQL.

## Documentation

Module docs are on [HexDocs](https://hexdocs.pm/squatch_mail) once published;
until then, `mix docs` builds them locally. Start with `SquatchMail.Config`
for configuration, `SquatchMail.Tracker` for the read/write API the dashboard
and webhook layers are built on, `SquatchMail.Migrations` for the migration
contract, and `SquatchMail.Web.Router` for mounting and the security model.

See also [`RESEARCH.md`](RESEARCH.md) (architecture and ecosystem survey),
[`FEATURES.md`](FEATURES.md) (feature inventory vs. LaraSend), and
[`DESIGN.md`](DESIGN.md) (the dashboard's visual design spec) for everything
that doesn't belong in module docs. [`CHANGELOG.md`](CHANGELOG.md) tracks
what's shipped release over release.

## License

MIT
