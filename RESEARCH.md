# SquatchMail — Research & Architecture Recommendations

*Research date: 2026-07-08. Inspiration: [LaraSend](https://larasend.com/) ([repo](https://github.com/savvyagents/larasend)) — a self-hosted SES dashboard + sending API for Laravel.*

## What LaraSend actually is

- **Standalone Laravel app** (Inertia/Vue UI, PostgreSQL, Redis, queue worker) shipped via Docker Compose. One `curl` + `docker compose up -d` to install.
- **HTTP API** (`POST /api/emails`) with project-scoped, hashed API keys.
- **Laravel package** providing a Symfony Mailer transport: set `MAIL_MAILER=larasend` and every existing mailable/notification flows through the LaraSend server unchanged.
- Server stores MIME + metadata, queues delivery, sends via **SES v2 `SendEmail`**.
- **SES event ingestion** (delivery, bounce, complaint, open, click, suppression) via configuration-set event publishing → webhook back into the app.
- Dashboard: activity timeline, rendered previews, headers, raw MIME, DKIM/DNS checks, suppression lists, SES quota sync, webhook retry logs.

## Key finding: Elixir can be *more* seamless than LaraSend

Two integration mechanisms exist in Elixir, and we should ship both:

### 1. Swoosh telemetry capture (zero-code observability — no Laravel equivalent)

`Swoosh.Mailer.deliver/2` wraps every send in `:telemetry.span/3`, emitting
`[:swoosh, :deliver, :start | :stop | :exception]` (and `:deliver_many` variants).
The metadata includes the **full `%Swoosh.Email{}` struct, the mailer module, adapter config, and the delivery `result` — which for SES adapters includes the SES `message_id`** (the correlation key for bounce/open/click events).

→ A single `:telemetry.attach_many/4` at boot captures *all* outgoing mail from a host app with **zero config changes and no adapter swap**. The host keeps sending directly through its existing SES adapter.

Caveats: telemetry handlers run in the caller process — hand off to a GenServer/Oban job immediately, never raise; persist on `:stop`/`:exception`, not `:start`. Bamboo apps aren't covered (no built-in telemetry) — offer an optional Bamboo adapter wrapper later.

### 2. Custom Swoosh adapter (LaraSend-parity proxy mode)

The `MAIL_MAILER=larasend` equivalent is a `config/runtime.exs` block:

```elixir
config :my_app, MyApp.Mailer,
  adapter: SquatchMail.Adapter,
  api_key: System.get_env("SQUATCHMAIL_API_KEY"),
  base_url: System.get_env("SQUATCHMAIL_URL")
```

Swoosh reads mailer config at delivery time, so this is a pure config change; all existing `Mailer.deliver/1` calls flow through unchanged. Writing the adapter is ~150–300 LOC:
`use Swoosh.Adapter, required_config: [:api_key]` + `deliver/2` (+ optional `deliver_many/2`) POSTing JSON via `Swoosh.ApiClient` (Hackney/Finch/Req abstraction — zero HTTP deps of our own). Template: [Postmark adapter](https://github.com/swoosh/swoosh/blob/main/lib/swoosh/adapters/postmark.ex).

## Ecosystem survey (sending)

| Package | Verdict |
|---|---|
| `swoosh` 1.26.x | Default Phoenix mailer, very active (~1.5M recent downloads). **The integration surface.** |
| `Swoosh.Adapters.AmazonSES` / `ExAwsAmazonSES` | Both use **SES v1** `SendRawEmail` (MIME via `gen_smtp`). ExAws variant adds credential-chain/IAM-role support. |
| `bamboo` / `bamboo_ses` | Bamboo in maintenance mode; `bamboo_ses` notably *does* use SES v2. Optional adapter later. |
| `ex_aws_ses` | Stale (last release 2022, mostly v1). **Avoid.** |
| **`aws` (aws-elixir) `AWS.SESv2`** | Full, maintained SES v2 surface: `send_email/3`, `create_configuration_set/3`, `create_configuration_set_event_destination/4`, suppression, account/quota. **Use for the server side.** |
| `ex_aws_sns` | Maintained; ships `ExAws.SNS.verify_message/1` (SNS signature verification, SigV1+SigV2, cert caching). **Use for webhook verification** (validate `SigningCertURL` host ourselves; prefer SignatureVersion 2). |

**SES events pipeline**: configuration set → SNS event destination → HTTPS subscription → our Phoenix controller. Handle `SubscriptionConfirmation` (GET `SubscribeURL` after validating TopicArn), verify signatures, key events by `mail.messageId`. Event types: Send, Delivery, Bounce, Complaint, Reject, Open, Click, Rendering Failure, DeliveryDelay, Subscription. Because we control the SES call (or the config set), we can **auto-provision** the config set + SNS topic + subscription via `AWS.SESv2` — a "Connect SES" button instead of an AWS-console afternoon.

**Prior art**: no direct competitor exists in Elixir. [Keila](https://github.com/pentacent/keila) has the best existing SNS→SES-event ingestion code to study. `Plug.Swoosh.MailboxPreview` (`/dev/mailbox`) means every Phoenix dev already has the "page that shows sent email" muscle memory — SquatchMail is the production version. dwyl/email (retired) proves demand. **The gap is real**: both Swoosh SES adapters are stuck on v1 and `ex_aws_ses` is stale.

## Distribution research (how to be "zero-setup")

The Elixir ecosystem's proven model is the **embeddable Hex-package dashboard** (Phoenix LiveDashboard, Oban Web, ErrorTracker — the closest analog):

- **Router macro**: `import SquatchMail.Router` + `squatch_mail_dashboard "/squatch"` in a `:browser` scope. Expands to `live_session` + routes + asset route.
- **Precompiled assets** in `priv/static`, served content-hashed by the macro's asset route. **No npm/Tailwind/asset-pipeline changes in the host.** (Backpex's require-host-Tailwind approach is the anti-pattern — avoid.)
- **Versioned migrations** behind one API (Oban/ErrorTracker pattern): host generates one migration calling `SquatchMail.Migrations.up(version: n)`.
- **Resolver behaviour** (Oban Web pattern) for host-controlled auth/access instead of inventing our own.
- **Igniter installer**: `mix igniter.install squatch_mail` runs a `squatch_mail.install` task that patches `mix.exs`, config, router, and generates the migration. Oban, ErrorTracker, and the whole Ash suite ship these. **True one-command setup — beats LaraSend's one .env line.**

**Standalone model** (for polyglot shops / LaraSend parity): Plausible CE is the canon — dedicated `community-edition` repo with `compose.yml` + `.env` (BASE_URL, SECRET_KEY_BASE, AWS creds), entrypoint auto-runs `createdb` + `migrate`, image on ghcr.io. SquatchMail needs only 2 services (app + Postgres) — no Redis/ClickHouse; Oban runs in-BEAM on Postgres.

**Ash fit**: use Ash freely in the **standalone app** (resources, AshAuthentication for dashboard login, AshAdmin, AshJsonApi if wanted). Keep Ash **out of the embeddable library** — every successful embeddable dashboard depends on nothing heavier than `ecto_sql` + `phoenix_live_view`, and forcing ash/spark/reactor onto host apps (with version-constraint clashes for hosts already on Ash) would kill adoption.

## Recommended architecture

**One core, two shells** — a shared plain-Ecto core (schemas, event ingestion, SES client, suppression logic, LiveView components) wrapped by:

1. **`squatch_mail` Hex package (build first — "The Den")**
   - Telemetry capture of all Swoosh sends (mode 1) — works with the host's *existing* SES adapter.
   - `squatch_mail_dashboard "/squatch"` router macro + precompiled assets.
   - SNS webhook route (macro-mounted) + `ExAws.SNS.verify_message/1` + auto subscription confirmation.
   - One-click SES provisioning (config set + SNS topic + subscription) via `AWS.SESv2`.
   - Versioned migrations; data lives in the host's Postgres.
   - Igniter installer: `mix igniter.install squatch_mail` = done.
   - Deps: `ecto_sql`, `phoenix_live_view`, `telemetry`, `aws`, `ex_aws_sns`, `gen_smtp` (MIME). No Ash.

2. **Standalone Docker app (build second — "The Lodge")**
   - Thin Phoenix (+ Ash if desired) app embedding the core + dashboard, plus: API keys (hashed, one-time reveal), `POST /api/emails`, multi-project/workspace, Oban queue for sends/retries, SES v2 `SendEmail` (Raw MIME for fidelity), suppression enforcement, quota sync, DKIM/DNS checks, outbound webhook fan-out with retries.
   - `SquatchMail.Adapter` (mode 2) + potential SDKs for other languages — this is what serves non-Elixir apps.
   - Plausible-CE-style `compose.yml`, auto-migrating entrypoint, ghcr.io image.

**Why library-first**: it's the uniquely-Elixir wedge (LaraSend can't do in-app), it's the fastest path to "little to no setup," it requires no hosting decision from the user, and the standalone app is then mostly packaging + API keys around the same core.

## Sasquatch theming hooks

Tracking events = **Footprints**. Opens/clicks = **Sightings**. Suppression list = **The Blacklist... er, "Do Not Disturb the Forest"**. Bounce = **"Lost in the woods."** Tagline candidates: *"Big footprint. Tiny bill."* / *"Every email leaves footprints."* / *"Elusive no more."*

## Open questions / risks

- Open/click tracking: SES-native (config-set) tracking vs own pixel/redirect domain — SES-native is zero-infra; custom domain gives nicer links. Start SES-native.
- Email body storage: full MIME storage grows fast — need retention policy / pruning (Oban job) + optional S3 offload.
- Telemetry mode captures sends the host makes *outside* Swoosh (raw ex_aws calls) — document as unsupported.
- Multi-node hosts: telemetry capture works per-node; fine since persistence is via shared Postgres.
