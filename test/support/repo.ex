defmodule SquatchMail.Test.Repo do
  @moduledoc false
  use Ecto.Repo, otp_app: :squatch_mail, adapter: Ecto.Adapters.Postgres
end

defmodule SquatchMail.Test.UnsandboxedRepo do
  @moduledoc """
  A second connection to the same `squatch_mail_test` database as
  `SquatchMail.Test.Repo`, but with a plain (non-sandbox) pool.

  `Ecto.Migrator` runs each migration in its own spawned process with its
  own connection checkout, entirely outside `Ecto.Adapters.SQL.Sandbox`'s
  per-test ownership tracking. Flipping `SquatchMail.Test.Repo`'s sandbox
  mode to `:auto` to accommodate that (as a previous attempt at the
  migration-upgrade test did) affects the pool for *every* concurrently
  running `async: true` test, not just the one that needs it — breaking
  every other test's isolation for the duration. This repo exists so a
  migration-upgrade test can run `Ecto.Migrator` against a real connection
  without ever touching `SquatchMail.Test.Repo`'s sandbox state.
  """
  use Ecto.Repo, otp_app: :squatch_mail, adapter: Ecto.Adapters.Postgres
end
