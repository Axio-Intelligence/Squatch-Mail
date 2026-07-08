# Changelog

All notable changes to SquatchMail are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); SquatchMail
follows [Semantic Versioning](https://semver.org/) once it reaches 1.0.

## [Unreleased]

Pre-1.0 development. Nothing has been published to Hex yet — this section
tracks work landed on `main` so far. See `FEATURES.md` for the full parity
checklist against LaraSend, including what's still planned.

### Added

- **Core data layer.** `SquatchMail.Migrations` — versioned, host-owned
  migrations following the Oban/ErrorTracker pattern (`up/1`, `down/1`,
  `migrated_version/1`; version tracked via a Postgres `COMMENT ON TABLE`,
  not a separate tracking table). `V01` creates the `squatch_mail` schema and
  all core tables: `emails`, `email_recipients`, `email_attachments`,
  `email_events`, `suppressions`, `webhook_logs`, `sources`. `SquatchMail.Tracker`
  is the context module the rest of the library reads/writes through:
  recording emails and their nested recipients/attachments in one
  transaction, event ingestion with message-id linking (including orphan
  events that arrive before their email does), status-rank tracking so a
  bounce or complaint can never be silently overwritten by a later, weaker
  event, suppression management with expiry, filtered activity queries,
  aggregate stats with prior-period deltas, and retention-based pruning.
- **Swoosh telemetry capture.** `SquatchMail.Capture` attaches to
  `[:swoosh, :deliver | :deliver_many, :stop | :exception]` at application
  boot and records every outgoing email the host sends through its existing
  Swoosh mailer — no adapter swap, no code changes to the send path.
  Handling is off the caller's process (`GenServer.cast/2` to
  `SquatchMail.Capture.Recorder`) with a bounded queue, so a capture backlog
  degrades by dropping and logging rather than by blocking sends or growing
  unbounded.
- **SES integration.** `SquatchMail.SES` wraps `AWS.SESv2`/`AWS.SNS` (via the
  shared `SquatchMail.Finch` pool, no hackney): one-click provisioning of a
  configuration set, SNS topic, HTTPS subscription, and event destination
  (`provision/1,3`); sending-quota sync with a six-hour cache
  (`sync_quota/1,2`, `ensure_quota_synced/1`); sending-identity listing with
  verification and DKIM status (`list_identities/1`, `create_identity/1,2`,
  `recheck_identity/1,2`); and pure DKIM/SPF/DMARC DNS record guidance
  (`dns_records_for/1`). AWS credentials resolve from the `sources` row
  either statically (stored keys) or ambiently (environment variables) — see
  `SECURITY.md` for the at-rest caveat on static credentials.
- **Igniter installer.** `mix igniter.install squatch_mail` patches
  `mix.exs`, application config, the host router, and generates the
  migration in one step; a fully manual install path is documented in
  `README.md` for hosts not using igniter.
- Project documentation: `RESEARCH.md` (architecture and ecosystem survey),
  `FEATURES.md` (feature inventory mapped against LaraSend, with P1/P2
  phasing), `DESIGN.md` (dashboard visual design spec), `SECURITY.md`
  (vulnerability reporting and the dashboard/webhook/credentials security
  model), and this changelog.

### In progress (landing on `main`, not yet in a checklist item above)

- SNS webhook ingestion: signature verification, message processing, and the
  SES event → email status / suppression pipeline.
- Dashboard foundation: router macro (`SquatchMail.Web.Router` /
  `squatch_mail_dashboard/1,2`), the three-layer access control model
  (host-owned auth, HTTP Basic Auth fallback, refuse-by-default), layout,
  and self-contained precompiled assets.
- Retention/pruning as a scheduled worker (the underlying
  `SquatchMail.Tracker.prune/0` logic already ships; wiring it to run on a
  schedule is pending).

### Known gaps

- Dashboard activity feed, email inspector, stats, suppression management,
  and Base Camp settings pages are not yet built (`SquatchMail.Web.Router`
  currently mounts placeholder LiveViews for these routes).
- Live DNS re-checking (actual `:inet_res` lookups against published DKIM/SPF
  records) is not implemented; `SquatchMail.SES.recheck_identity/1,2`
  currently re-queries SES's own verification status instead.
- `credentials_mode: "static"` stores `access_key_id`/`secret_access_key` as
  plaintext columns; encryption at rest is a tracked TODO, not yet done.
