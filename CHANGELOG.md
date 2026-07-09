# Changelog

All notable changes to SquatchMail are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); SquatchMail
follows [Semantic Versioning](https://semver.org/) once it reaches 1.0.

## [Unreleased]

Nothing yet.

## [0.1.0] — 2026-07-09

First release published to Hex. See `FEATURES.md` for the full parity
checklist against LaraSend.

### Added

- **The dashboard.** One router macro (`squatch_mail_dashboard`) mounts the
  full LiveView dashboard with self-contained, content-hashed assets and
  three-layer access control (host-owned auth via `:on_mount`, HTTP Basic
  Auth fallback, refuse-by-default otherwise — see `README.md`'s "Keeping
  the Forest Safe"). Pages: the Trail Log (live activity feed with stats,
  filters, and CSV export), the per-email Sighting inspector (preview,
  headers, Footprint timeline, raw), the Do-Not-Disturb suppression
  registry, and Base Camp (SES connection, one-click provisioning, quota,
  identities, DNS guidance with live re-checks via
  `SquatchMail.SES.check_dns/2`).
- **Sightings, Bounces, and Complaints pages.** The sidebar's three
  remaining nav items now have routes (`/sightings`, `/bounces`,
  `/complaints`) instead of 404ing. All three are served by
  `SquatchMail.Web.Live.TrailLog` via `live_action` page configs: the
  Sightings archive lists every email on record (all-time default range);
  Bounces and Complaints are the same table locked to status
  `bounced`/`complained` — the status select is hidden and a hand-typed
  `?status=` param can't unlock it. CSV export links on each page carry the
  locked status and effective range, and the Sighting inspector's back link
  now returns to whichever page (and filter set) the user came from.
  Instead of the Trail Log's engagement column, Bounces shows a Reason
  column (SES `bounceType · bounceSubType` plus the recipient's
  `diagnosticCode`) and Complaints shows the ISP's `complaintFeedbackType`,
  backed by `SquatchMail.Tracker.bounce_details/1` /
  `complaint_details/1` — one latest-event-per-email query each, no per-row
  N+1.
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
  event (`next_status/2`), suppression management with expiry, filtered
  activity queries, aggregate stats with prior-period deltas, and
  retention-based pruning (`prune/0`).
- **Swoosh telemetry capture.** `SquatchMail.Capture` attaches to
  `[:swoosh, :deliver | :deliver_many, :stop | :exception]` at application
  boot and records every outgoing email the host sends through its existing
  Swoosh mailer — no adapter swap, no code changes to the send path.
  Handling is off the caller's process (`GenServer.cast/2` to
  `SquatchMail.Capture.Recorder`) with a bounded queue, so a capture backlog
  degrades by dropping and logging rather than by blocking sends or growing
  unbounded.
- **SNS/SES event ingestion.** `SquatchMail.SNS.MessageVerifier` hand-verifies
  inbound SNS message signatures (SigV1/SigV2) against `:public_key` with no
  new dependency, validating the `SigningCertURL` host/scheme before fetching
  it and caching parsed certificates in ETS. `SquatchMail.SNS.Processor`
  orchestrates constant-time webhook-token lookup, payload normalization
  (both `eventType`- and legacy `notificationType`-style SES payloads),
  `Tracker.record_event/1` calls, bounce/complaint-driven suppression, and
  dedupe on `(message_id, event_type, recipient, occurred_at)` to survive
  SNS's at-least-once delivery. Every inbound payload is logged via
  `Tracker.log_webhook/1` regardless of outcome.
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
- **Guardrails and retention.** `SquatchMail.Guard` checks every send
  against the suppression list and a complaint-rate circuit breaker
  (auto-pauses sending at a configurable complaint rate — `0.1%` by default,
  matching SES's own account-suspension threshold — with a minimum-volume
  floor so a handful of early sends can't produce a false positive).
  `SquatchMail.Adapters.Watchtower` is an opt-in Swoosh adapter that enforces
  `Guard` ahead of a wrapped real adapter, all-or-nothing across
  `deliver_many/2` batches, for hosts who want a suppressed recipient to
  actually block the send rather than only be recorded after the fact.
  `SquatchMail.Pruner` is a supervised timer that runs `Tracker.prune/0` on a
  configurable interval (six hours by default), also pruning `webhook_logs`
  on a fixed 30-day window.
- **Igniter installer.** `mix igniter.install squatch_mail` patches
  `mix.exs`, application config, the host router, and generates the
  migration in one step; a fully manual install path is documented in
  `README.md` for hosts not using igniter.
- Project documentation: `RESEARCH.md` (architecture and ecosystem survey),
  `FEATURES.md` (feature inventory mapped against LaraSend, with P1/P2
  phasing), `DESIGN.md` (dashboard visual design spec), `SECURITY.md`
  (vulnerability reporting and the dashboard/webhook/credentials security
  model), `LICENSE` (MIT), and this changelog.

### Known gaps

- `credentials_mode: "static"` stores `access_key_id`/`secret_access_key` as
  plaintext columns; encryption at rest is a tracked TODO, not yet done.
- Ambient credentials read `AWS_*` environment variables only; EC2/ECS
  instance- and task-role resolution via the metadata service is a
  documented follow-up (see `SquatchMail.SES`).
