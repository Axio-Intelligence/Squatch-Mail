# SquatchMail feature inventory (derived from LaraSend source, 2026-07-08)

Ground truth extracted from a clone of `savvyagents/larasend` (models, migrations, routes, services, jobs) — not marketing copy. Each section lists what LaraSend actually implements, mapped to SquatchMail phases: **P1** = embeddable Hex package, **P2** = standalone Docker app, **—** = skip/replace.

## Domain model (their 15 tables → our schema design)

| LaraSend table | Purpose | SquatchMail |
|---|---|---|
| `workspaces`, `workspace_user` (role) | Multi-tenant workspace + member roles | P2 only (P1 inherits host-app auth via Resolver) |
| `projects` (slug, default_environment, archived_at) | Grouping unit; env = prod/staging per project | P2 (P1: single implicit project, tag by env) |
| `sources` | **The SES connection**: region, AWS keys (encrypted), session token, config set name, default from, webhook token, retention_days, monthly_quota, max_send_rate, last_quota (JSON) + checked_at | P1 (single source) / P2 (per-project) |
| `domains` (status, dns_records JSON, verified_at) | Sending identities + DKIM/SPF/DMARC record guidance, re-check DNS | P1 |
| `api_keys` (prefix, key_hash sha, last_used_at, expires_at + governance fields) | Hashed keys, one-time reveal, rotate, expiry | P2 only (P1 needs no keys — in-process) |
| `templates` (slug, subject, html, text, variables JSON) | Named templates w/ variable substitution | P2 / later |
| `emails` | public_id, status, ses_message_id, from, subject, html+text bodies, **MIME stored on disk** (mime_disk/path/size), headers JSON, tags JSON, sent_at | P1 core |
| `email_recipients` (type to/cc/bcc, email, name) | Normalized recipients, searchable | P1 core |
| `email_attachments` (filename, content_type, size, disposition) | Attachment metadata (not content) | P1 core |
| `email_events` | event_type, ses_message_id, recipient, url (click), user_agent, ip, raw payload JSON, occurred_at | P1 core ("footprints") |
| `suppressions` | per-project unique email, reason, source event, expires_at (soft bounces expire!) | P1 core |
| `webhook_logs` | Raw inbound SNS/SES webhook audit: message_type, status, payload, error | P1 |
| `webhook_endpoints` (url, events[], signing secret w/ prefix, status, last_delivered_at) | User-defined outbound webhooks | P2 / later |
| `webhook_deliveries` (http_status, latency_ms, status, response_body, delivered_at) | Outbound delivery attempts + retry log | P2 / later |

## Send pipeline (`EmailSendService`, `SendQueuedEmail`, `MimeMessageBuilder`, `SesV2Client`)

- Accept → validate → **guardrails** → persist (email + recipients + attachments + MIME to disk) → queue → worker sends via SES v2 `SendEmail` (raw MIME) → status transitions queued→sending→sent→(events).
- **Guardrails they enforce pre-send** (P1/P2 must-haves):
  - From-domain must be a verified domain (ValidationException otherwise).
  - Recipients checked against suppression list — send rejected listing suppressed addresses.
  - **Auto-pause: 30-day complaint rate ≥ 0.1% blocks sending** (SES's own account-suspension threshold).
  - Quota freshness: cached SES quota re-synced if older than 6h; sends accepted even when quota sync is stale (SES is final authority).
- Retry semantics: transient SES errors retried by the queue; final failure recorded on the email's timeline (their launch-review commit fixed dead retry paths — design ours as an Oban worker with explicit states from day one).
- Dashboard "Send test email" form + per-email **Resend** + bulk **retry soft bounces**.

## Event ingestion (`SesWebhookController`, `SnsSignatureVerifier`, `SesEventNormalizer`)

- Endpoint: `POST /webhooks/ses/{token}` — random per-source token in URL (defense in depth) + SNS signature verification + SubscriptionConfirmation handling. Every inbound payload logged to `webhook_logs` with status/error (P1).
- Normalizer maps SES event → recipient extraction per type (bouncedRecipients / complainedRecipients / recipients[0]) and email status: delivery→delivered, open→opened, click→clicked, bounce→bounced, complaint→complained, reject→rejected, deliverydelay→delayed. Click events capture url/userAgent/ip (P1).
- Events matched to emails by `ses_message_id`; events stored even if no matching email (null email_id).
- Bounce/complaint → suppression insert (soft bounces get `expires_at`; hard bounces permanent).

## Dashboard UI (routes/web.php sections)

Sections: **activity** (default), **sent, bounces, complaints, suppressions, identities (domains), templates, webhooks, api-keys, send, setup** + projects index + onboarding wizard.

- Activity: status filters, search, grouped timeline (last hour / earlier today), engagement counts (opens ◎ / clicks ↗), live updates, **CSV export** (`activity/export`).
- Email inspector: rendered HTML **preview** (`emails/{id}/preview`), **raw MIME** download (`emails/{id}/mime`), headers, tags, event timeline, metrics, resend button.
- Identities: add domain → shown DKIM/SPF/DMARC/bounce records → one-click DNS re-check (`DnsRecordVerifier` does live DNS lookups).
- Source panel: SES quota sync button, region/credentials editing.
- Onboarding wizard: workspace → SES credentials → domain → API key (P2; P1's equivalent is the igniter installer + "Connect SES" page).
- Auth: full user system w/ 2FA (Fortify) — P2 only; P1 delegates to host app.

## Public API (routes/api.php — deliberately tiny)

- `GET /api/emails` (list/filter), `POST /api/emails` (send), `GET /api/emails/{id}` (status+events). API-key auth. That's the whole surface (P2).

## Ops features

- Docker image, compose stack (app + Postgres + Redis + queue worker), php.ini/nginx tuned for 30MB attachments, retention_days per source (data pruning), monthly_quota + max_send_rate caps per source.
- P1 equivalents: Oban pruning job honoring `retention_days`; attachment size limit configurable; no Redis needed (Oban on Postgres).

## Features SquatchMail gets that LaraSend doesn't have

- **Telemetry capture mode**: observe all Swoosh mail without proxying the send path (P1's headline).
- **Auto-provisioning**: create the SES configuration set + SNS topic + HTTPS subscription via `AWS.SESv2`/SNS APIs from the "Connect SES" flow (LaraSend makes users configure event publishing manually).
- LiveView-native real-time activity feed (they fake "live" with polling/Inertia).
