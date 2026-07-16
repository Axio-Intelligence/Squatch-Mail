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

              /'-.       .-'\      /'-.       .-'\
             /     '-. .-'    \   /     '-. .-'    \
            '.        '        '.'         '       .'
```

# SquatchMail

**Big footprint. Tiny bill.**

*The self-hosted Amazon SES dashboard for Elixir. Your emails are out
there. SquatchMail finds them.*

SquatchMail is a self-hosted Amazon SES email dashboard for Phoenix
applications, shipped as an embeddable Hex package — the ErrorTracker / Oban
Web model, not a Docker Compose stack you have to babysit. Add the
dependency, run one migration, mount one route, and every email your app
sends through SES gets a live activity feed, delivery/open/click tracking,
bounce and complaint handling, and a suppression list, all backed by tables
that live quietly in their own Postgres schema inside your existing database.

No queue to stand up. No Redis. No separate service to deploy, monitor, and
eventually forget about. If your Phoenix app already talks to SES,
SquatchMail is mostly just... there, the way a footprint is there whether or
not you were looking for it.

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

## FIELD EVIDENCE

What the expedition has actually turned up so far:

- **Zero-config send observability.** SquatchMail attaches to Swoosh's
  telemetry events (`[:swoosh, :deliver | :deliver_many, :stop | :exception]`)
  at boot and captures every send your app makes through its *existing* Swoosh mailer —
  no adapter swap, no proxy, no code changes to your send path. This is the
  thing LaraSend and friends structurally cannot do, because they aren't
  living inside your BEAM node.
- **SES event ingestion.** An SNS-backed webhook pipeline (hand-verified
  SigV1/SigV2 signatures against `:public_key`, no `ex_aws` dependency) turns
  delivery, bounce, complaint, open, click, reject, and delay notifications
  into a per-email timeline of Footprints, and automatically maintains your
  suppression list (hard bounces and complaints are permanent; soft bounces
  expire). Every inbound payload is logged for audit regardless of outcome.
- **One-click SES provisioning.** "Connect SES" from Base Camp creates the
  configuration set, SNS topic, HTTPS subscription, and event destination for
  you via `AWS.SESv2`/`AWS.SNS` — the manual afternoon LaraSend asks you to
  spend in the AWS console, done from a button.
- **Identity + DKIM guidance, with live DNS re-checks.** List your sending
  identities, see verification and DKIM status, and get copy-paste DNS
  records (CNAME for DKIM, TXT for SPF/DMARC) instead of AWS's own
  documentation tabs. A "re-check DNS" button resolves each expected record
  against public DNS (`SquatchMail.SES.check_dns/2`, via OTP's `:inet_res` —
  no new dependency) and reports pass/warn/missing per record, alongside
  SES's own verification verdict. Quota sync, cached for six hours, so Base
  Camp doesn't hammer `GetAccount` on every page load.
- **Status that only ever tells the truth.** A later, weaker event can never
  quietly downgrade an email's status — a delivery notification arriving
  after a click is recorded as a Footprint but doesn't un-click the email,
  and bounces/complaints/rejections always win outright. See
  `SquatchMail.Tracker.next_status/2` if you want to see the ranking.
- **Guardrails, not just observation.** `SquatchMail.Guard` checks every
  send against the suppression list and a complaint-rate circuit breaker
  (auto-pauses sending at a 0.1% complaint rate by default — SES's own
  account-suspension threshold — with a minimum-volume floor so five sends
  and one complaint doesn't read as a 20% rate). Most hosts only need
  `SquatchMail.Capture`'s pure observation, but `SquatchMail.Adapters.Watchtower`
  is an opt-in Swoosh adapter for hosts who want a suppressed recipient or
  an auto-paused account to actually block the send, not just get recorded
  after the fact.
- **It cleans up after itself.** `SquatchMail.Pruner` runs
  `SquatchMail.Tracker.prune/0` on a timer (six hours by default), deleting
  emails and their footprints past your configured `retention_days` and
  webhook audit logs past a fixed 30-day window, so the forest doesn't just
  keep accumulating footprints forever.
- **Your database, your rules.** Every table lives inside its own
  `squatch_mail` Postgres schema (configurable), versioned and migrated the
  same way Oban and ErrorTracker do it — one host-owned migration file that
  calls `SquatchMail.Migrations.up()`, safe to re-run as new versions ship.

- **The dashboard itself.** Trail Log (live activity feed with stats,
  filters, and CSV export), the Sightings archive, dedicated Bounces and
  Complaints views, the per-email Sighting inspector (preview, headers,
  Footprint timeline, raw), the Do-Not-Disturb registry, and Base Camp —
  all served from one router macro with self-contained assets.

Still being tracked, not yet a confirmed sighting: credential encryption at
rest for static-mode AWS keys. See the checklist below and
[`FEATURES.md`](FEATURES.md) for the full inventory.

## What raw SES makes you build yourself

| | Raw `AWS.SESv2` calls | A hosted SES-wrapper API | SquatchMail |
|---|---|---|---|
| Send observability | Nothing — you get a `message_id` and silence | Usually yes, on their servers | Yes, in **your** Postgres, via Swoosh telemetry — zero code changes |
| Bounce/complaint handling | Wire up SNS yourself, from scratch | Built in | Built in, hand-verified signatures, no proxy |
| Suppression list | Build and enforce it yourself | Built in | Built in, with bounce-type-aware expiry, plus an optional adapter that blocks the send outright |
| Where your data lives | Nowhere (SES doesn't keep a timeline) | Their database, their retention policy | Your database, your schema, your `retention_days` |
| Setup | AWS console, by hand | Sign up, get an API key, integrate their SDK | `mix igniter.install squatch_mail` |
| Extra infrastructure | None, but also none of the above | A vendor dependency | None — it's a library, not a service |

## TRACKING METHODOLOGY

How a Sighting actually gets tracked, in two halves — outbound and inbound:

```
 OUTBOUND (a send happens)
 ──────────────────────────

   Your app                SquatchMail                 Your database
 ┌────────────┐   deliver ┌───────────────┐   record  ┌─────────────────┐
 │ Swoosh      │ ───────▶ │ :telemetry    │ ────────▶ │ squatch_mail.*   │
 │ Mailer      │  (:stop) │ span capture  │  (async,  │ (emails,         │
 │ .deliver/2  │          │ (Capture)     │   never   │  recipients,     │
 └────────────┘          └───────────────┘   blocks)  │  attachments)    │
                                                        └─────────────────┘
       no adapter swap · no proxy · your existing SES call, observed


 INBOUND (SES reports back what happened to it)
 ───────────────────────────────────────────────

 ┌─────┐   event   ┌─────┐  HTTPS POST  ┌──────────────────┐   verified,   ┌─────────────────┐
 │ SES │ ────────▶ │ SNS │ ───────────▶ │ webhook endpoint  │ ───────────▶ │ squatch_mail.*   │
 └─────┘           └─────┘  (signed)    │ (token + SigV1/2  │  normalized   │ (email_events =  │
                                         │  signature check) │   event      │  "Footprints",   │
                                         └──────────────────┘               │  suppressions)   │
                                                                             └─────────────────┘
       delivery → delivered · open → opened · click → clicked
       bounce → bounced (+ suppression) · complaint → complained (+ suppression)
```

Both halves land in the same `squatch_mail` Postgres schema, which the
dashboard reads from directly. No queue, no separate service, no polling.

## SETTING UP BASE CAMP

### With igniter (recommended)

If your project already uses [igniter](https://hexdocs.pm/igniter), add
SquatchMail and run its installer in one step:

```bash
mix igniter.install squatch_mail
```

This adds `:squatch_mail` to `mix.exs`, configures it in `config.exs`,
generates the migration that creates its tables, mounts the dashboard in
your router at `/squatch`, and teaches your endpoint to preserve the raw
bytes SNS webhook signatures need (see step 5 of the manual path below for
what this actually does, and why it's the one thing that can't be avoided).

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
   `SquatchMail.Config` for all supported options, including the telemetry
   capture engine's `:capture` options (HTML/text body retention, sample
   rate), the guardrails' `:guard` options (complaint-rate threshold,
   auto-pause), and `:pruner` (retention sweep interval).

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

5. **The SNS webhook's raw body — nothing to wire up.** SquatchMail's SNS
   webhook needs the *exact bytes* SNS sent to verify the request's
   signature. `squatch_mail_dashboard` handles this for you: the webhook
   route pipes through `SquatchMail.SNS.RawBodyPlug`, which captures the raw
   body in SquatchMail's own pipeline — no endpoint changes, no `:body_reader`
   to configure.

   This works even though your endpoint's `Plug.Parsers` runs first: SNS
   delivers with `Content-Type: text/plain; charset=UTF-8`, which
   `Plug.Parsers` matches no parser for and (with `pass: ["*/*"]`) passes
   through with the body still unread — so those bytes are still there for
   `RawBodyPlug` to read. (An endpoint `:body_reader`, the old recommendation,
   never even fires for `text/plain`, which is why it wasn't enough.)

   If you already capture the raw body yourself (e.g. a `Plug.Parsers`
   `:body_reader` delegating to `SquatchMail.SNS.RawBodyReader`), that still
   works — `RawBodyPlug` detects an already-set `conn.assigns[:raw_body]` and
   stands down. It's optional now, not required.

   **Read the "Keeping the Forest Safe" section below before you deploy
   this anywhere but your own laptop.**

## KEEPING THE FOREST SAFE

SquatchMail ships three layers of dashboard access control
(`SquatchMail.Web.Router` + `SquatchMail.Web.Plugs.Auth`). Exactly one
applies to any given request to a dashboard page (Trail Log, Sightings,
Suppressions, Base Camp): a configured `:basic_auth` wins over everything;
otherwise a host-supplied `:on_mount` means the host owns auth; otherwise
the dashboard refuses to render. The inbound SNS webhook route is never
covered by any of them — it authenticates itself independently (see below).

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
per-user scoping, SSO. Layers (b) and (c) are meant as a safety net for hosts
that mount the dashboard without wiring up their own auth, not a substitute
for doing so. Note that both the `pipe_through` and the `:on_mount` hook
matter: the plug pipeline gates the initial HTTP request, and the hook
re-checks on the LiveView socket — see the `SquatchMail.Web.Router`
moduledoc for why a plug alone can't protect the websocket after mount.

**b) Built-in fallback: HTTP Basic Auth.** Configure

```elixir
config :squatch_mail,
  basic_auth: [username: "squatch", password: System.fetch_env!("SQUATCH_MAIL_PASSWORD")]
```

and every dashboard route is protected by `Plug.BasicAuth` (a real 401 with
a `www-authenticate` challenge) — for small deployments that want
*something* stronger than wide open without standing up a real admin
pipeline. When set, this takes precedence over everything else, including a
configured `:on_mount` — setting `:basic_auth` is an explicit, unambiguous
request for that gate.

**c) Safe default: refuse.** If neither (a) nor (b) applies, SquatchMail
checks `Application.get_env(:squatch_mail, :allow_unauthenticated, false)` —
a runtime flag, not `Mix.env()`, which doesn't exist in a release and would
silently disable this exact safeguard in production. Unless that flag is
explicitly `true` (fine in `dev.exs`; never set it in production), every
dashboard request is halted with a 403 refusal page that explains the three
options above instead of rendering any data.

**The SNS webhook.** `SquatchMail.SNS.MessageVerifier`
hand-verifies inbound SNS message signatures (SigV1/SigV2) against
`:public_key`, with no third-party dependency, validating the
`SigningCertURL` host/scheme before ever fetching it and caching parsed
certificates in ETS for the certificate's own validity window.
`SquatchMail.SNS.Processor` rejects a payload with a missing or invalid
signature before it can touch your data, and every inbound payload — verified
or not — is logged via `SquatchMail.Tracker.log_webhook/1` for audit. This
does not depend on the dashboard auth layers above; it's independent
token-plus-signature authentication for a machine-to-machine endpoint.

**Credentials at rest.** AWS credentials for SES/SNS provisioning are either
read from the environment (`credentials_mode: "ambient"`, the default — no
keys touch your database) or, if you opt into `credentials_mode: "static"`,
stored as plaintext columns on the `sources` table today. Encrypting
`access_key_id`/`secret_access_key` at rest is a known gap, tracked as a TODO
in `SquatchMail.Source` — prefer ambient credentials until that lands. Note
that ambient mode reads `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/
`AWS_SESSION_TOKEN` from the environment only — it does **not** resolve EC2
instance or ECS task role credentials via the metadata service (a documented
follow-up in `SquatchMail.SES`). On a role-based deployment, export the
credentials into the environment or inject your own `%AWS.Client{}`.

**Found a security issue?** See [`SECURITY.md`](SECURITY.md) for how to
report it.

## Feature parity checklist

Tracking against the [LaraSend](https://larasend.com/) feature inventory
documented in [`FEATURES.md`](FEATURES.md). **P1** = this embeddable library;
**P2** = a future standalone app; **—** = intentionally out of scope for P1.
Status here reflects what's actually committed to `main`, not what's in an
open pull request or a teammate's working tree.

| Feature | Status | Notes |
|---|---|---|
| Zero-config Swoosh telemetry capture | Shipped | `SquatchMail.Capture` — LaraSend has no equivalent |
| Versioned migrations (Oban/ErrorTracker pattern) | Shipped | `SquatchMail.Migrations`, schema-comment version tracking |
| Core schema (emails, recipients, attachments, events, suppressions, webhook logs, source) | Shipped | `SquatchMail.Tracker` context |
| SES event ingestion (SNS webhook, signature verification, event normalizer) | Shipped | `SquatchMail.SNS.MessageVerifier`/`Processor`, hand-rolled signatures, no `ex_aws` |
| Suppression list (hard bounce/complaint permanent, soft bounce expiring) | Shipped | enforced in `SquatchMail.Tracker` and the SNS processor |
| One-click SES provisioning (config set + SNS topic + subscription) | Shipped | `SquatchMail.SES.provision/1` — LaraSend requires manual console setup |
| SES quota sync (6h cache) | Shipped | `SquatchMail.SES.ensure_quota_synced/1` |
| Identity list + DKIM/verification status + DNS record guidance | Shipped | `SquatchMail.SES.list_identities/1`, `dns_records_for/1` |
| Live DNS re-check | Shipped | `SquatchMail.SES.check_dns/2` resolves expected records via `:inet_res`; wired to Base Camp's "re-check DNS" button alongside the SES-side `recheck_identity/1` |
| Dashboard foundation (router macro, auth, layout, self-contained assets) | Shipped | `SquatchMail.Web.Router` — one macro, embedded assets, three auth layers |
| Activity feed + email inspector + stats | Shipped | Trail Log, Sightings archive, Sighting inspector |
| Suppressions / bounces / complaints / settings pages | Shipped | Do-Not-Disturb registry, Bounces/Complaints views, Base Camp |
| Complaint-rate auto-pause circuit breaker | Shipped | `SquatchMail.Guard.check/1`, min-volume floor, 0.1% default threshold |
| Send-path enforcement (optional) | Shipped | `SquatchMail.Adapters.Watchtower` — opt-in Swoosh adapter, blocks rather than only observes |
| Retention pruning | Shipped | `SquatchMail.Pruner` runs `Tracker.prune/0` on a timer; also prunes `webhook_logs` on a fixed 30-day window |
| Igniter installer + manual install path | Shipped | `mix igniter.install squatch_mail` |
| Credential encryption at rest (static mode) | Planned | see "Keeping the Forest Safe" |
| Templates, workspaces, API keys, outbound webhooks, multi-project | — | P2 (standalone app) scope, not P1 |

## Requirements

Elixir 1.15+, Ecto 3.13+, Phoenix LiveView 1.0+, PostgreSQL.

## Documentation

Module docs are on [HexDocs](https://hexdocs.pm/squatch_mail) once published;
until then, `mix docs` builds them locally. Start with `SquatchMail.Config`
for configuration, `SquatchMail.Tracker` for the read/write API the dashboard
and webhook layers are built on, `SquatchMail.Migrations` for the migration
contract, and `SquatchMail.SES` for the "Connect SES" provisioning flow.

See also [`RESEARCH.md`](RESEARCH.md) (architecture and ecosystem survey),
[`FEATURES.md`](FEATURES.md) (feature inventory vs. LaraSend), and
[`DESIGN.md`](DESIGN.md) (the dashboard's visual design spec and the full
Sighting/Footprint/Base Camp glossary) for everything that doesn't belong in
module docs. [`CHANGELOG.md`](CHANGELOG.md) tracks what's shipped release
over release.

## JOIN THE EXPEDITION

Issues and pull requests are welcome — this is early, pre-1.0 work.
Read `CLAUDE.md` for the naming conventions this codebase holds
itself to (boring code, bigfoot-flavored UI copy only) before sending a
patch, and see [`SECURITY.md`](SECURITY.md) if what you found is a
vulnerability rather than a bug.

### Working on SquatchMail locally

You need Elixir 1.15+ and a Postgres to point at — either one you run
yourself (connection settings honor the standard
`PGUSER`/`PGPASSWORD`/`PGHOST`/`PGPORT` environment variables) or the
Dockerized one the test host brings along (see loop 3; once it exists,
`PGPORT=5433 PGUSER=postgres PGPASSWORD=postgres` points loops 1 and 2 at
it, no local Postgres install required). Three loops, from fastest to most
realistic:

1. **The test suite.** `mix test` — creates and migrates its own
   `squatch_mail_test` database. Run it before sending a patch.

2. **The dashboard preview.** `mix dev` boots a minimal Phoenix endpoint
   with the dashboard at [http://localhost:4000/squatch](http://localhost:4000/squatch),
   backed by a `squatch_mail_dev` database that's created and migrated
   automatically. This is the fast loop for dashboard/UI work. Run it as
   `iex -S mix dev` and you can send emails through the preview's Swoosh
   mailer (`SquatchMailDev.Mailer`) to watch them flow through the capture
   pipeline — see the header of `dev.exs` for a copy-paste snippet.

3. **A real host app.** For anything touching the installer, migrations, or
   the host-integration story, scaffold a throwaway Phoenix app that embeds
   SquatchMail the way a real project would:

   ```bash
   bin/setup_test_host
   ```

   This generates `test_host/` (gitignored) with `mix phx.new`, adds
   SquatchMail as a *path dependency* pointing back at your checkout, runs
   `mix squatch_mail.install` — so it doubles as a smoke test of the
   igniter installer against a stock Phoenix app — and writes a
   `Dockerfile` + `docker-compose.yml` pinned to the latest stable
   Elixir/OTP and Postgres. Then:

   ```bash
   cd test_host
   docker compose up --build
   ```

   (No Docker? `mix phx.server` works too, against whatever Postgres your
   `PG*` variables point at.)

   The dashboard is at `/squatch`, Swoosh's local mailbox at `/dev/mailbox`;
   send mail through `TestHost.Mailer` and it shows up in both. Your
   checkout is bind-mounted into the app container, so library changes are
   picked up on recompile — restart the app service. Delete the directory
   and re-run the script whenever you want a fresh host.

## License

MIT — see [`LICENSE`](LICENSE).
