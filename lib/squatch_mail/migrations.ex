defmodule SquatchMail.Migrations do
  @moduledoc """
  Versioned migrations for SquatchMail's database tables.

  SquatchMail keeps its tables isolated in their own Postgres schema (the
  `:prefix`, `"squatch_mail"` by default) inside the host application's database.
  Rather than shipping raw, hand-editable migrations, all schema changes are
  applied through this single, versioned entrypoint — the same pattern used by
  Oban and ErrorTracker.

  ## Usage

  The host application generates one migration that delegates here:

      defmodule MyApp.Repo.Migrations.AddSquatchMail do
        use Ecto.Migration

        def up, do: SquatchMail.Migrations.up()
        def down, do: SquatchMail.Migrations.down()
      end

  Then runs it with `mix ecto.migrate`. Later SquatchMail releases add new
  versions; the host generates another migration pinned to a version:

      def up, do: SquatchMail.Migrations.up(version: 2)
      def down, do: SquatchMail.Migrations.down(version: 1)

  ## Options

    * `:prefix` - the Postgres schema to create the tables in. Defaults to
      `SquatchMail.Config.prefix/0` (`"squatch_mail"`).
    * `:version` - the version to migrate to. Defaults to the latest version.
    * `:create_schema` - whether to `CREATE SCHEMA IF NOT EXISTS` for the
      prefix. Defaults to `true`. Set to `false` when the schema is managed
      externally or when the prefix is `"public"`.

  The applied version is tracked as a `COMMENT` on the `emails` table (mirroring
  Oban, which comments `oban_jobs`), so re-running `up/1` is idempotent and only
  the outstanding versions run.
  """

  @doc """
  Migrates SquatchMail's tables up to the given (or latest) version.
  """
  @spec up(Keyword.t()) :: :ok
  defdelegate up(opts \\ []), to: SquatchMail.Migration

  @doc """
  Rolls SquatchMail's tables back down to the given version (default `0`).
  """
  @spec down(Keyword.t()) :: :ok
  defdelegate down(opts \\ []), to: SquatchMail.Migration

  @doc """
  Returns the currently-migrated version for the given prefix (0 if none).
  """
  @spec migrated_version(Keyword.t()) :: non_neg_integer()
  defdelegate migrated_version(opts \\ []), to: SquatchMail.Migration
end
