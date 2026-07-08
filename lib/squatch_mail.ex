defmodule SquatchMail do
  @moduledoc """
  SquatchMail is a self-hosted Amazon SES email dashboard, shipped as an
  embeddable Hex package for Phoenix applications.

  Add `:squatch_mail` as a dependency, run its migration, and mount
  `squatch_mail_dashboard "/squatch"` in your router to get a LiveView
  email-observability dashboard backed by your own PostgreSQL database.

  This module has no functions of its own — it's the documentation entry
  point. Depending on what you're doing, start with:

    * `SquatchMail.Config` — configuration keys (`:repo`, `:prefix`, etc.).
    * `SquatchMail.Migrations` — the versioned migration API a host calls
      from its own migration file.
    * `SquatchMail.Web.Router` — mounting `squatch_mail_dashboard/1,2` and
      the three-layer dashboard security model.
    * `SquatchMail.Tracker` — the read/write context backing the dashboard,
      webhook ingestion, and telemetry capture; useful if you're inspecting
      SquatchMail's data from IEx or a host-side task.
    * `SquatchMail.SES` — SES/SNS provisioning, quota sync, and identity/DKIM
      checks behind the "Connect SES" flow.

  See the project's `README.md` for installation, `FEATURES.md` for the full
  feature inventory and what's still planned, and `SECURITY.md` for the
  dashboard/webhook/credentials security model in one place.

  ## Requirements

  SquatchMail requires Elixir 1.15+, Ecto 3.13+, Phoenix LiveView 1.0+, and
  PostgreSQL.
  """
end
