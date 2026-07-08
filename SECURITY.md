# Security Policy

## Reporting a vulnerability

If you find a security issue in SquatchMail, please report it privately
rather than opening a public GitHub issue — email
**security@axio-intelligence.com** with a description and, if you have one, a
reproduction. We'll acknowledge within a few business days.

Please do not include real AWS credentials, production SNS payloads, or
other sensitive data in a report; a minimal, sanitized reproduction is more
useful to us anyway.

## Supported versions

SquatchMail is pre-1.0. Until a 1.0 release, only the latest published
version receives security fixes.

## Dashboard access control

SquatchMail's dashboard ships **refuse-by-default** outside of the three
supported access-control layers (host-owned auth, HTTP Basic Auth, or an
explicit `allow_unauthenticated: true` opt-in). See the "Security" section of
[`README.md`](README.md) and the `SquatchMail.Web.Router` module docs for the
full model. If you find a request path that bypasses all three layers,
that's a vulnerability — please report it as above.

## SNS webhook authenticity

The inbound `POST .../webhooks/sns/:token` route is a machine-to-machine
endpoint authenticated by two independent mechanisms: a random per-source
token in the URL path, and hand-rolled SNS message signature verification
(against `:public_key`/`:httpc`, deliberately not a third-party dependency)
performed before any payload is trusted. If you find a payload that's
accepted despite a missing or invalid signature, or a signature-verification
bypass, please report it as above rather than filing a public issue.

## Credentials at rest

AWS credentials for SES/SNS provisioning default to `credentials_mode:
"ambient"` (read from the environment; nothing touches the database). If a
host opts into `credentials_mode: "static"`, `access_key_id` and
`secret_access_key` are currently stored as plaintext columns on the
`sources` table — this is a known, tracked gap (see the `# TODO: encrypt at
rest` comment in `SquatchMail.Source`), not a surprise we're hiding. Prefer
ambient credentials until encryption-at-rest lands. This is tracked as
regular project work, not a vulnerability report — see `FEATURES.md`'s parity
checklist for status.

## Dependency posture

SquatchMail deliberately keeps its dependency surface small (`ecto_sql`,
`phoenix`/`phoenix_live_view`, `plug`, `telemetry`, `aws`, `finch`) and avoids
pulling in additional third-party packages to do security-sensitive work like
SNS signature verification or AWS credential-chain resolution — see
`CLAUDE.md` for the reasoning. If you believe one of our dependencies has a
disclosed vulnerability that affects SquatchMail, please still report it
through the channel above so we can assess and patch on our own timeline
rather than waiting on a transitive update.
