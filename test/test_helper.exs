{:ok, _} = Application.ensure_all_started(:squatch_mail)

repo = SquatchMail.Test.Repo
repo.__adapter__().storage_up(repo.config())

{:ok, _pid} = repo.start_link()

# See SquatchMail.Test.UnsandboxedRepo's moduledoc: a second, non-sandboxed
# connection to the same database, used only by the migration-upgrade test
# in migrations_test.exs so it can drive Ecto.Migrator without flipping
# SquatchMail.Test.Repo's sandbox mode (which would affect every other
# concurrently-running test).
{:ok, _pid} = SquatchMail.Test.UnsandboxedRepo.start_link()

# Rebuild SquatchMail's schema from scratch on every run. Recreating the whole
# `squatch_mail` schema is simpler to reason about than partial-version
# detection for a throwaway test database. The migration is driven through
# `Ecto.Migrator` (rather than calling `SquatchMail.Migrations.up/1` directly)
# so that Ecto's migration runner process — which `create table`, `execute`,
# and the version-tracking query all depend on — is present.
prefix = SquatchMail.Config.prefix()
repo.query!("DROP SCHEMA IF EXISTS #{inspect(prefix)} CASCADE")

# `DROP SCHEMA` above wipes SquatchMail's tables but not Ecto's own
# `schema_migrations` bookkeeping (which lives in the default schema). Clear the
# example migration's version too, otherwise `Ecto.Migrator.up` would consider
# it already applied and skip recreating the tables. Guarded because the table
# won't exist on a brand-new database.
repo.query!("""
DO $$
BEGIN
  IF to_regclass('public.schema_migrations') IS NOT NULL THEN
    DELETE FROM schema_migrations WHERE version = 20260708000000;
  END IF;
END $$;
""")

Code.require_file("priv/repo/migrations/20260708000000_add_squatch_mail.exs")
Ecto.Migrator.up(repo, 20_260_708_000_000, SquatchMail.Repo.Migrations.AddSquatchMail)

Ecto.Adapters.SQL.Sandbox.mode(repo, :manual)

ExUnit.start()
