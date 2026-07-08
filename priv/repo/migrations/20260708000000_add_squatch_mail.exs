defmodule SquatchMail.Repo.Migrations.AddSquatchMail do
  @moduledoc """
  Example host migration for SquatchMail.

  This is the single migration a host application generates to install (and
  later upgrade) SquatchMail's tables. It delegates entirely to the versioned
  `SquatchMail.Migrations` API — never edit the SquatchMail tables by hand.

  Copy this file into your own `priv/repo/migrations/` with a fresh timestamp
  (or generate it via the installer), then run `mix ecto.migrate`.
  """

  use Ecto.Migration

  def up, do: SquatchMail.Migrations.up()

  def down, do: SquatchMail.Migrations.down()
end
