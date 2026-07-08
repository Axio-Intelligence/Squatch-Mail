# SquatchMail — agent conventions

SquatchMail is a self-hosted Amazon SES email dashboard shipped as an
embeddable Hex package (the ErrorTracker / Oban Web model): a host Phoenix
app adds the dep, runs a migration, mounts `squatch_mail_dashboard "/squatch"`
in its router, and gets a LiveView email-observability dashboard.

Read `RESEARCH.md`, `FEATURES.md`, and `DESIGN.md` first — they define the
architecture, the LaraSend feature parity map, and the visual theme. Keep
them up to date as the design evolves; don't let this file duplicate them.

## Naming

- Code names are boring and professional: `Email`, `EmailEvent`,
  `Suppression`. Never bigfoot-themed identifiers in modules, schemas,
  tables, or function names.
- Bigfoot flavor (footprints, sightings, "lost in the woods," etc.) is
  reserved for UI copy, README prose, and docs — never for code.

## Library boundaries

- This is the embeddable library ("The Den" in RESEARCH.md), not the
  standalone app ("The Lodge"). Keep dependencies minimal: `ecto_sql`,
  `phoenix`/`phoenix_live_view`, `plug`, `telemetry`, `aws` + `finch`. No Ash,
  no ex_aws, no Bamboo. SNS signature verification is hand-written against
  `:public_key`/`:httpc` — don't reach for a dependency to do it.
- Swoosh is an optional dependency: we observe host sends via telemetry, we
  don't require the host to install anything beyond Swoosh itself.

## Ecto & migrations

- All Ecto schemas set `@schema_prefix "squatch_mail"` (or read
  `SquatchMail.Config.prefix/0` where a literal module attribute isn't
  possible) so tables stay isolated in their own Postgres schema in the
  host's database. Never assume the `public` schema.
- Schema modules `use Milesvalue.Schema`-style conventions do **not** apply
  here — this is a different project. Use plain `Ecto.Schema` with explicit
  `@primary_key {:id, :binary_id, autogenerate: true}` (UUIDs), since
  SquatchMail has no equivalent of `Milesvalue.Schema` and shouldn't invent
  one prematurely.
- All schema/table changes ship as versioned migrations behind one API,
  following the Oban/ErrorTracker pattern: the host generates a single
  migration that calls `SquatchMail.Migrations.up(version: n)` /
  `SquatchMail.Migrations.down(version: n)`. Never hand hosts a raw,
  unversioned migration.

## Workflow

- Run `mix format` before committing.
- Run `mix test` before declaring any task done — it must pass.
- `mix compile` should stay clean; don't paper over warnings, fix them.
