defmodule SquatchMail.Migrations.Postgres.V02 do
  @moduledoc false

  use Ecto.Migration

  @doc false
  def up(%{prefix: prefix}) do
    # SquatchMail.Guard filters on `sent_at` (the complaint-rate breaker's
    # trailing-window volume/rate queries) on every guarded send, uncached
    # by design. Without an index this is a full scan of `emails` once the
    # table grows past what Postgres will happily sequential-scan. Partial
    # (`WHERE sent_at IS NOT NULL`) because captured-but-not-yet-sent emails
    # never match Guard's `not is_nil(e.sent_at)` filter, so there's no
    # value indexing those rows.
    create_if_not_exists index(:emails, [:sent_at],
                           prefix: prefix,
                           where: "sent_at IS NOT NULL"
                         )

    :ok
  end

  @doc false
  def down(%{prefix: prefix}) do
    drop_if_exists index(:emails, [:sent_at], prefix: prefix)

    :ok
  end
end
