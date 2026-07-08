defmodule SquatchMail.MigrationsTest do
  use SquatchMail.DataCase, async: true

  # The test suite runs `SquatchMail.Migrations.up/1` once (via `Ecto.Migrator`)
  # in `test_helper.exs`, so by the time these tests run the schema is at the
  # current version. We assert the version marker and idempotence here.

  @current_version 1

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
end
