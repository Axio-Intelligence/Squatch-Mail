defmodule SquatchMail.Migration do
  @moduledoc false

  # Adapter-dispatching migrator. SquatchMail is Postgres-only, so this simply
  # forwards to `SquatchMail.Migrations.Postgres`. Kept as a separate layer to
  # mirror the Oban structure and leave room for other adapters later.

  use Ecto.Migration

  @doc false
  @spec up(Keyword.t()) :: :ok
  def up(opts \\ []) when is_list(opts) do
    SquatchMail.Migrations.Postgres.up(opts)
  end

  @doc false
  @spec down(Keyword.t()) :: :ok
  def down(opts \\ []) when is_list(opts) do
    SquatchMail.Migrations.Postgres.down(opts)
  end

  @doc false
  @spec migrated_version(Keyword.t()) :: non_neg_integer()
  def migrated_version(opts \\ []) when is_list(opts) do
    SquatchMail.Migrations.Postgres.migrated_version(opts)
  end
end
