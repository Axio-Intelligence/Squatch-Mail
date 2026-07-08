defmodule SquatchMail.MigrationsTest do
  use SquatchMail.DataCase, async: true

  import ExUnit.CaptureLog

  alias SquatchMail.Test.UnsandboxedRepo

  # The test suite runs `SquatchMail.Migrations.up/1` once (via `Ecto.Migrator`)
  # in `test_helper.exs`, so by the time these tests run the schema is at the
  # current version. We assert the version marker and idempotence here.

  @current_version 2

  test "migrated_version reflects the applied version" do
    assert SquatchMail.Migrations.migrated_version(repo: Repo) == @current_version
  end

  test "the version is recorded as a COMMENT on the emails table" do
    %{rows: [[comment]]} =
      Repo.query!("""
      SELECT pg_catalog.obj_description(pc.oid, 'pg_class')
      FROM pg_catalog.pg_class pc
      JOIN pg_catalog.pg_namespace pn ON pn.oid = pc.relnamespace
      WHERE pc.relname = 'emails' AND pn.nspname = 'squatch_mail'
      """)

    assert comment == to_string(@current_version)
  end

  test "all expected tables exist in the squatch_mail schema" do
    %{rows: rows} =
      Repo.query!("""
      SELECT table_name FROM information_schema.tables
      WHERE table_schema = 'squatch_mail'
      ORDER BY table_name
      """)

    tables = List.flatten(rows)

    for expected <- ~w(emails email_recipients email_attachments email_events
                       suppressions webhook_logs sources) do
      assert expected in tables, "expected table #{expected} to exist"
    end
  end

  test "V02 created a partial index on emails.sent_at" do
    %{rows: rows} =
      Repo.query!("""
      SELECT indexname FROM pg_indexes
      WHERE schemaname = 'squatch_mail' AND tablename = 'emails'
      """)

    indexes = List.flatten(rows)
    assert Enum.any?(indexes, &String.contains?(&1, "sent_at"))
  end

  # `SquatchMail.Migrations.up/1` and `down/1` call plain `Ecto.Migration`
  # functions (`create`, `drop_if_exists`, `execute`), which only work inside
  # an `Ecto.Migration.Runner` process — the same reason test_helper.exs
  # drives the initial migration through `Ecto.Migrator.up/3` rather than
  # calling `SquatchMail.Migrations.up/1` directly. These throwaway migration
  # modules give `Ecto.Migrator.up/4` something to run, pinned to specific
  # version numbers, so the upgrade test below can exercise the real
  # `SquatchMail.Migrations.up/1` / `down/1` API.
  #
  # Everything runs against `@upgrade_prefix` (a dedicated Postgres schema no
  # other test touches) through `SquatchMail.Test.UnsandboxedRepo` (a
  # dedicated, non-sandboxed connection — see its moduledoc). An earlier
  # version of this test flipped `SquatchMail.Test.Repo`'s sandbox mode to
  # `:auto` instead, which affects the pool for every concurrently-running
  # `async: true` test, not just this one — that broke other tests'
  # isolation intermittently under `mix test`'s parallel scheduling. Using a
  # wholly separate connection avoids touching the shared repo's sandbox
  # state at all.
  @upgrade_prefix "squatch_mail_migration_upgrade_test"

  # Ecto's `schema_migrations` bookkeeping is global (not scoped per
  # Postgres schema/prefix), so these version numbers must never collide
  # with the real example migration's timestamp version, or with each
  # other, or a stale row left behind by an aborted previous run of this
  # test could make `Ecto.Migrator.up/4` wrongly treat one of these steps
  # as already-applied and silently skip it.
  @migrator_v_initial 88_880_000_001
  @migrator_v_down_to_1 88_880_000_002
  @migrator_v_up_to_2 88_880_000_003

  defmodule UpToInitial do
    @moduledoc false
    use Ecto.Migration
    def up, do: SquatchMail.Migrations.up(prefix: "squatch_mail_migration_upgrade_test")
    def down, do: :ok
  end

  defmodule DownToV1 do
    @moduledoc false
    use Ecto.Migration

    def up,
      do: SquatchMail.Migrations.down(prefix: "squatch_mail_migration_upgrade_test", version: 1)

    def down, do: :ok
  end

  defmodule UpToV2 do
    @moduledoc false
    use Ecto.Migration

    def up,
      do: SquatchMail.Migrations.up(prefix: "squatch_mail_migration_upgrade_test", version: 2)

    def down, do: :ok
  end

  defp cleanup_upgrade_test_state do
    UnsandboxedRepo.query!("DROP SCHEMA IF EXISTS #{inspect(@upgrade_prefix)} CASCADE")

    UnsandboxedRepo.query!(
      "DELETE FROM schema_migrations WHERE version IN ($1, $2, $3)",
      [@migrator_v_initial, @migrator_v_down_to_1, @migrator_v_up_to_2]
    )
  end

  test "a host still on V01 upgrades cleanly to V02 via up/1" do
    on_exit(&cleanup_upgrade_test_state/0)

    # Clean up first too, in case a previous run of this same test aborted
    # before its own on_exit ran and left stale state behind.
    cleanup_upgrade_test_state()

    # Install fresh (latest version) in the dedicated schema, then roll back
    # to V01 — simulating "a host that installed SquatchMail before the
    # sent_at index shipped" — entirely through the versioned API under
    # test, never by hand-crafting schema state.
    #
    # (capture_log/1 only silences Ecto.Migrator's own harmless "you're
    # running an out-of-order version number" warning, expected here since
    # these throwaway modules use arbitrary version integers alongside the
    # real timestamp-versioned example migration in schema_migrations.)
    capture_log(fn -> Ecto.Migrator.up(UnsandboxedRepo, @migrator_v_initial, UpToInitial) end)
    capture_log(fn -> Ecto.Migrator.up(UnsandboxedRepo, @migrator_v_down_to_1, DownToV1) end)

    assert SquatchMail.Migrations.migrated_version(
             repo: UnsandboxedRepo,
             prefix: @upgrade_prefix
           ) == 1

    %{rows: pre_upgrade_indexes} =
      UnsandboxedRepo.query!(
        """
        SELECT indexname FROM pg_indexes
        WHERE schemaname = $1 AND tablename = 'emails'
        """,
        [@upgrade_prefix]
      )

    refute Enum.any?(List.flatten(pre_upgrade_indexes), &String.contains?(&1, "sent_at"))

    capture_log(fn -> Ecto.Migrator.up(UnsandboxedRepo, @migrator_v_up_to_2, UpToV2) end)

    assert SquatchMail.Migrations.migrated_version(
             repo: UnsandboxedRepo,
             prefix: @upgrade_prefix
           ) == 2

    %{rows: post_upgrade_indexes} =
      UnsandboxedRepo.query!(
        """
        SELECT indexname FROM pg_indexes
        WHERE schemaname = $1 AND tablename = 'emails'
        """,
        [@upgrade_prefix]
      )

    assert Enum.any?(List.flatten(post_upgrade_indexes), &String.contains?(&1, "sent_at"))

    # All V01 tables must still be intact after the upgrade.
    %{rows: rows} =
      UnsandboxedRepo.query!(
        """
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = $1
        ORDER BY table_name
        """,
        [@upgrade_prefix]
      )

    tables = List.flatten(rows)

    for expected <- ~w(emails email_recipients email_attachments email_events
                       suppressions webhook_logs sources) do
      assert expected in tables, "expected table #{expected} to survive the upgrade"
    end
  end
end
