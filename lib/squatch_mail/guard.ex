defmodule SquatchMail.Guard do
  @moduledoc """
  Pre-send guardrails: suppression enforcement and the complaint-rate
  auto-pause.

  Every send SquatchMail observes or proxies should be checked against
  `check/1` first. Two independent conditions can block a send:

    * **Suppression** - any recipient address with an active suppression
      row (hard bounce, soft bounce not yet expired, complaint, or manual).
      See `SquatchMail.Tracker.suppressed_addresses/1` / `list_suppressions/1`
      for how "active" is defined (`expires_at IS NULL OR expires_at >
      now()`).
    * **Complaint-rate auto-pause** - if the fraction of sent emails
      complained about, over the trailing
      `SquatchMail.Config.complaint_rate_window_days/0` days, is at or above
      `SquatchMail.Config.complaint_rate_threshold/0` (`0.1%` by default —
      SES's own account-suspension threshold), sending is paused entirely
      regardless of recipient. Below `SquatchMail.Config.complaint_rate_min_volume/0`
      sent emails in the window the breaker never trips, even at 100% complaints,
      so a handful of early sends can't produce a false positive (1 complaint
      out of 5 sends is not a 20% complaint rate in any meaningful sense).
      Disable the breaker entirely with `complaint_rate_pause: false`.

  This module never sends anything itself, nor does it touch the network —
  it only reads from `SquatchMail.Tracker`. See `SquatchMail.Adapters.Watchtower`
  for a Swoosh adapter that enforces this automatically ahead of a wrapped
  real adapter, and `resend/2` for re-sending a previously-captured email
  through the host's own mailer.

  ## Performance note

  `check/1` runs one query for suppressions (`Tracker.suppressed_addresses/1`,
  `WHERE address IN (...) AND (expires_at IS NULL OR expires_at > now())`
  — a single round trip regardless of recipient count) and, when the
  breaker is enabled, one aggregate query for the complaint rate — every
  call, no caching. For a proxy adapter sitting in the hot send path this
  means two extra round trips per send (one, if the address list is empty
  and the rate check is disabled). That's an accepted cost for correctness
  today; if it shows up in profiling, the complaint rate is the obvious
  candidate to cache (e.g. recomputed on a timer rather than per-send)
  since it only needs to change a few times a day, not per-request.
  """

  import Ecto.Query

  alias SquatchMail.{Config, Email, Tracker}

  @typedoc """
  Why a send was blocked by `check/1`.
  """
  @type block_reason :: {:suppressed, [String.t()]} | :complaint_rate_paused

  @typedoc "Anything `check/1` can be called with."
  @type recipients_input :: Swoosh.Email.t() | String.t() | [String.t()]

  @doc """
  Checks recipients against SquatchMail's guardrails ahead of a send.

  Accepts a `%Swoosh.Email{}` (its `:to`/`:cc`/`:bcc` addresses are
  extracted), a single address, or a list of addresses.

  Returns `:ok` if the send should proceed, or `{:error, reason}` if it
  should be blocked:

    * `{:error, {:suppressed, addresses}}` - one or more recipients are
      actively suppressed; `addresses` lists every suppressed recipient
      found, not just the first.
    * `{:error, :complaint_rate_paused}` - the account-wide complaint rate
      is at or above threshold; sending is paused regardless of recipient.

  The complaint-rate check runs first — it's a single aggregate query
  regardless of recipient count and blocks the entire send outright before
  bothering to look at individual addresses.
  """
  @spec check(recipients_input()) :: :ok | {:error, block_reason()}
  def check(%Swoosh.Email{} = email) do
    check(addresses(email))
  end

  def check(address) when is_binary(address) do
    check([address])
  end

  def check(addresses) when is_list(addresses) do
    with :ok <- check_complaint_rate() do
      check_suppressions(addresses)
    end
  end

  @doc """
  Returns the current trailing-window complaint rate (a fraction,
  `0.0`..`1.0`), regardless of whether it exceeds the configured threshold
  or how many emails have been sent. Useful for a dashboard health panel.

  Returns `0.0` when there have been no sends in the window (nothing to
  divide by, and nothing to complain about).
  """
  @spec complaint_rate() :: float()
  def complaint_rate, do: current_complaint_rate()

  @doc """
  Returns `true` if sending is currently auto-paused due to the complaint
  rate exceeding its threshold at or above the configured minimum volume.

  Always `false` when `complaint_rate_pause: false` is configured.
  """
  @spec paused?() :: boolean()
  def paused? do
    Config.complaint_rate_pause?() and volume_met?() and
      current_complaint_rate() >= Config.complaint_rate_threshold()
  end

  @doc """
  Re-sends a previously-captured email through the host's own configured
  Swoosh mailer.

  `mailer` is the host's `Swoosh.Mailer` module (the same one the original
  send went through, or any other). Builds a fresh `%Swoosh.Email{}` from
  the stored subject/bodies/recipients and delivers it — this is a genuine
  new send (and will itself be captured again if telemetry capture is
  enabled), not a replay of the original SES request. Runs through
  `check/1` first, same as any other send, so resending to a suppressed
  address or while paused is rejected the same way.
  """
  @spec resend(Email.t(), module()) :: {:ok, term()} | {:error, block_reason() | term()}
  def resend(%Email{} = email, mailer) when is_atom(mailer) do
    email = Config.repo().preload(email, [:recipients, :attachments])
    swoosh_email = build_swoosh_email(email)

    with :ok <- check(swoosh_email) do
      mailer.deliver(swoosh_email)
    end
  end

  defp check_complaint_rate do
    if paused?(), do: {:error, :complaint_rate_paused}, else: :ok
  end

  defp check_suppressions(addresses) do
    suppressed =
      addresses
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Tracker.suppressed_addresses()

    case suppressed do
      [] -> :ok
      _ -> {:error, {:suppressed, suppressed}}
    end
  end

  defp volume_met? do
    window_days = Config.complaint_rate_window_days()
    cutoff = DateTime.add(DateTime.utc_now(), -window_days * 86_400, :second)

    query = from e in Email, where: not is_nil(e.sent_at) and e.sent_at >= ^cutoff

    Config.repo().aggregate(query, :count, :id) >= Config.complaint_rate_min_volume()
  end

  defp current_complaint_rate do
    window_days = Config.complaint_rate_window_days()
    cutoff = DateTime.add(DateTime.utc_now(), -window_days * 86_400, :second)

    query =
      from e in Email,
        where: not is_nil(e.sent_at) and e.sent_at >= ^cutoff,
        select: %{
          total: count(e.id),
          complained: filter(count(e.id), e.status == "complained")
        }

    case Config.repo().one(query) do
      %{total: 0} -> 0.0
      %{total: total, complained: complained} -> complained / total
      nil -> 0.0
    end
  end

  defp addresses(%Swoosh.Email{to: to, cc: cc, bcc: bcc}) do
    (List.wrap(to) ++ List.wrap(cc) ++ List.wrap(bcc))
    |> Enum.map(&mailbox_address/1)
    |> Enum.reject(&is_nil/1)
  end

  defp mailbox_address({_name, address}), do: address
  defp mailbox_address(address) when is_binary(address), do: address
  defp mailbox_address(_), do: nil

  defp build_swoosh_email(%Email{} = email) do
    swoosh_email =
      Swoosh.Email.new()
      |> Swoosh.Email.from({email.from_name || "", email.from_email})
      |> Swoosh.Email.subject(email.subject || "")

    swoosh_email =
      if email.html_body,
        do: Swoosh.Email.html_body(swoosh_email, email.html_body),
        else: swoosh_email

    swoosh_email =
      if email.text_body,
        do: Swoosh.Email.text_body(swoosh_email, email.text_body),
        else: swoosh_email

    Enum.reduce(email.recipients, swoosh_email, fn recipient, acc ->
      mailbox = {recipient.name || "", recipient.address}

      case recipient.kind do
        "cc" -> Swoosh.Email.cc(acc, mailbox)
        "bcc" -> Swoosh.Email.bcc(acc, mailbox)
        _ -> Swoosh.Email.to(acc, mailbox)
      end
    end)
  end
end
