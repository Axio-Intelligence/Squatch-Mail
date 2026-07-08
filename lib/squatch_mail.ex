defmodule SquatchMail do
  @moduledoc """
  SquatchMail is a self-hosted Amazon SES email dashboard, shipped as an
  embeddable Hex package for Phoenix applications.

  Add `:squatch_mail` as a dependency, run its migration, and mount
  `squatch_mail_dashboard "/squatch"` in your router to get a LiveView
  email-observability dashboard backed by your own PostgreSQL database.

  ## Requirements

  SquatchMail requires Elixir 1.15+, Ecto 3.13+, Phoenix LiveView 1.0+, and
  PostgreSQL.

  ## Configuration

  See `SquatchMail.Config` for the list of supported configuration keys.
  """
end
