defmodule SquatchMail.Adapters.Watchtower do
  @moduledoc """
  An opt-in Swoosh adapter that enforces `SquatchMail.Guard`'s guardrails
  ahead of a wrapped real adapter.

  This is the LaraSend-parity "proxy mode" from RESEARCH.md, applied to
  guardrails specifically: instead of only *observing* sends via telemetry
  (see `SquatchMail.TelemetryCapture`), Watchtower sits directly in the send path so
  a suppressed recipient or an auto-paused account can actually **block**
  the send rather than just be recorded after the fact.

  This is entirely optional — most hosts should prefer `SquatchMail.TelemetryCapture`
  (pure observation, zero risk of ever blocking a legitimate send by
  mistake) and only reach for Watchtower if they want suppressions and the
  complaint-rate auto-pause enforced *before* SES ever sees the request,
  rather than after the fact via `SquatchMail.Guard.check/1` called
  manually.

  ## Usage

  Configure a mailer to use Watchtower with the real ("watched") adapter and
  its own config flattened alongside it, under `:watched_adapter`:

      config :my_app, MyApp.Mailer,
        adapter: SquatchMail.Adapters.Watchtower,
        watched_adapter: Swoosh.Adapters.AmazonSES,
        region: "us-east-1",
        access_key: System.fetch_env!("AWS_ACCESS_KEY_ID"),
        secret: System.fetch_env!("AWS_SECRET_ACCESS_KEY")

  Watchtower itself declares no `required_config` of its own beyond
  `:watched_adapter` — everything else in `config` is passed straight
  through to the watched adapter untouched, including its own required
  keys, which are validated in `validate_config/1` by delegating to the
  watched adapter (with `:watched_adapter` stripped out first).

  ## All-or-nothing batches

  `deliver_many/2` checks every recipient across the *entire* batch before
  sending any of it. If any recipient anywhere in the batch is suppressed
  (or the account is paused), the whole call returns
  `{:error, {:suppressed, addresses}}` (or `{:error, :complaint_rate_paused}`)
  and **none** of the emails are sent — not even the ones with clean
  recipients. This is a deliberate simplicity/safety trade-off: partial
  sends would mean silently reordering or splitting a batch the caller
  asked to send atomically, and would require inventing a per-email result
  shape for a mixed outcome. A caller that wants partial delivery on
  suppression should call `deliver/2` per email instead.

  ## Capture interplay

  A blocked send still returns `{:error, reason}` from `deliver/2`, which
  means `Swoosh.Mailer` still emits its `[:swoosh, :deliver, :stop]`
  telemetry (with that error in metadata) exactly as it would for any other
  adapter failure — so `SquatchMail.TelemetryCapture` still records the attempt. See
  `SquatchMail.TelemetryCapture` for how `{:suppressed, _}` is recorded with status
  `"suppressed"` rather than `"failed"`.
  """

  # Not `use Swoosh.Adapter` — that macro always generates its own
  # `validate_config/1` (matching on whatever `required_config:` is passed,
  # `[]` by default), which would conflict with the hand-written one below.
  # We have no `required_config` of our own beyond `:watched_adapter`, which
  # needs custom logic (delegate to the watched adapter's own
  # validate_config/1), so we declare the behaviour directly instead.
  @behaviour Swoosh.Adapter

  alias SquatchMail.Guard

  @impl true
  def deliver(%Swoosh.Email{} = email, config) do
    with :ok <- Guard.check(email) do
      watched_adapter(config).deliver(email, watched_config(config))
    end
  end

  @impl true
  def deliver_many(emails, config) do
    all_addresses = emails |> Enum.flat_map(&addresses/1) |> Enum.uniq()

    with :ok <- Guard.check(all_addresses) do
      watched_adapter(config).deliver_many(emails, watched_config(config))
    end
  end

  @doc """
  Validates the watched adapter's own config.

  Requires `:watched_adapter` to be present, then delegates to that
  adapter's `validate_config/1` with `:watched_adapter` stripped from the
  config (so the watched adapter only ever sees keys it understands).
  Adapters that don't export `validate_config/1` (not part of the
  `Swoosh.Adapter` behaviour's required callbacks in every version) are
  treated as passing validation.
  """
  @impl true
  def validate_config(config) do
    adapter = Keyword.fetch!(config, :watched_adapter)

    try do
      adapter.validate_config(watched_config(config))
    rescue
      UndefinedFunctionError -> :ok
    end
  end

  defp watched_adapter(config), do: Keyword.fetch!(config, :watched_adapter)
  defp watched_config(config), do: Keyword.delete(config, :watched_adapter)

  defp addresses(%Swoosh.Email{to: to, cc: cc, bcc: bcc}) do
    (List.wrap(to) ++ List.wrap(cc) ++ List.wrap(bcc))
    |> Enum.map(&mailbox_address/1)
    |> Enum.reject(&is_nil/1)
  end

  defp mailbox_address({_name, address}), do: address
  defp mailbox_address(address) when is_binary(address), do: address
  defp mailbox_address(_), do: nil
end
