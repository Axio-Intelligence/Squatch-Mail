defmodule SquatchMail.TelemetryCapture do
  @moduledoc """
  Observes every `Swoosh.Mailer.deliver/2` and `deliver_many/2` call in the host
  application via `:telemetry`, with zero changes to the host's mailer or
  adapter.

  `Swoosh.Mailer` wraps each send in `:telemetry.span/3`, emitting
  `[:swoosh, :deliver | :deliver_many, :start | :stop | :exception]`. This
  module attaches to the `:stop` and `:exception` events (never `:start` — we
  only have a result to persist once the send has actually finished) and
  records the outcome via `SquatchMail.Tracker.record_email/1`.

  ## Design constraints

  Telemetry handlers run **synchronously in the caller's process** — the same
  process that just called `Mailer.deliver/2`. This module therefore:

    * never raises: every persistence step is wrapped and logged on failure
      rather than propagated, so a SquatchMail bug can never break the host's
      mail sending;
    * never blocks the caller: persistence is hopped off to
      `SquatchMail.TaskSupervisor` immediately, so the caller's `deliver/2`
      call returns as soon as the adapter itself returns.

  ## Adapter result normalization

  The `result` telemetry metadata is adapter-specific. This module recognizes:

    * `Swoosh.Adapters.AmazonSES` / `Swoosh.Adapters.ExAwsAmazonSES`:
      `%{id: message_id}` (atom-keyed).
    * Raw `AWS.SESv2.send_email/3` responses (for hosts using a custom adapter
      built directly on the `aws` package): `%{"MessageId" => message_id}`
      (string-keyed, PascalCase, straight off the wire).

  Any other adapter's result is still recorded — just without a `message_id`,
  which means SES event ingestion won't be able to correlate delivery/bounce
  events back to it later. Unrecognized shapes are never treated as an error.

  ## Configuration

      config :squatch_mail,
        enabled: true,
        sample_rate: 1.0

  `:enabled` (see `SquatchMail.Config.enabled?/0`) disables capture entirely.
  `:sample_rate` (see `SquatchMail.Config.sample_rate/0`) randomly skips a
  fraction of sends for very high-volume mailers; defaults to `1.0` (capture
  everything).
  """

  require Logger

  alias SquatchMail.{Config, Tracker}

  @handler_id "squatch-mail-telemetry-capture"

  @events [
    [:swoosh, :deliver, :stop],
    [:swoosh, :deliver, :exception],
    [:swoosh, :deliver_many, :stop],
    [:swoosh, :deliver_many, :exception]
  ]

  @doc """
  Attaches the capture handler. Safe to call more than once (re-attaching
  replaces the previous handler rather than erroring or double-firing).
  """
  @spec attach() :: :ok
  def attach do
    :telemetry.detach(@handler_id)

    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
  end

  @doc """
  Detaches the capture handler.
  """
  @spec detach() :: :ok
  def detach do
    :telemetry.detach(@handler_id)
  end

  @doc false
  def handle_event(event, measurements, metadata, config)

  def handle_event([:swoosh, :deliver, :stop], _measurements, metadata, _config) do
    if capture?() do
      dispatch(fn -> capture_single(metadata) end)
    end
  end

  def handle_event([:swoosh, :deliver, :exception], _measurements, metadata, _config) do
    if capture?() do
      dispatch(fn -> capture_single_exception(metadata) end)
    end
  end

  def handle_event([:swoosh, :deliver_many, :stop], _measurements, metadata, _config) do
    if capture?() do
      dispatch(fn -> capture_many(metadata) end)
    end
  end

  def handle_event([:swoosh, :deliver_many, :exception], _measurements, metadata, _config) do
    if capture?() do
      dispatch(fn -> capture_many_exception(metadata) end)
    end
  end

  # Never block the caller: hand persistence off to a supervised task. Falls
  # back to running inline (still guarded, still never raising) if the task
  # supervisor isn't running for some reason, e.g. in tests that call the
  # handler directly without starting the application.
  defp dispatch(fun) do
    case Process.whereis(SquatchMail.TaskSupervisor) do
      nil -> safely(fun)
      _pid -> Task.Supervisor.start_child(SquatchMail.TaskSupervisor, fn -> safely(fun) end)
    end

    :ok
  end

  defp safely(fun) do
    fun.()
  rescue
    error ->
      Logger.error(
        "SquatchMail failed to capture an outgoing email: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )
  end

  defp capture?, do: Config.enabled?() and sampled?()

  defp sampled? do
    case Config.sample_rate() do
      rate when rate >= 1.0 -> true
      rate when rate <= 0.0 -> false
      rate -> :rand.uniform() <= rate
    end
  end

  defp capture_single(%{email: email, mailer: mailer} = metadata) do
    result = Map.get(metadata, :result)
    error = Map.get(metadata, :error)

    attrs = email_attrs(email, mailer, result, error)
    record(attrs)
  end

  defp capture_single_exception(%{email: email, mailer: mailer, reason: reason}) do
    attrs = email_attrs(email, mailer, nil, reason)
    record(attrs)
  end

  defp capture_many(%{emails: emails, mailer: mailer} = metadata) do
    result = Map.get(metadata, :result)
    error = Map.get(metadata, :error)

    emails
    |> Enum.with_index()
    |> Enum.each(fn {email, index} ->
      attrs = email_attrs(email, mailer, result_for_index(result, index), error)
      record(attrs)
    end)
  end

  defp capture_many_exception(%{emails: emails, mailer: mailer, reason: reason}) do
    Enum.each(emails, fn email ->
      attrs = email_attrs(email, mailer, nil, reason)
      record(attrs)
    end)
  end

  # `deliver_many/2` results are adapter-specific about whether they return one
  # result per email or a single aggregate result; we only know how to line up
  # a list positionally. Anything else falls back to "no per-email result",
  # which just means no message_id gets recorded for these emails.
  defp result_for_index(results, index) when is_list(results), do: Enum.at(results, index)
  defp result_for_index(_results, _index), do: nil

  defp record(attrs) do
    case Tracker.record_email(attrs) do
      {:ok, _email} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "SquatchMail could not record a captured email: #{inspect(changeset.errors)}"
        )
    end
  end

  defp email_attrs(%Swoosh.Email{} = email, mailer, result, error) do
    message_id = extract_message_id(result)

    %{
      status: status_for(message_id, error),
      from_email: mailbox_address(email.from),
      from_name: mailbox_name(email.from),
      subject: email.subject,
      html_body: email.html_body,
      text_body: email.text_body,
      headers: stringify_map(email.headers),
      provider_options: stringify_map(email.provider_options),
      tags: extract_tags(email),
      mailer: inspect(mailer),
      message_id: message_id,
      sent_at: DateTime.utc_now(),
      error: format_error(error),
      recipients: recipients(email),
      attachments: attachments(email)
    }
  end

  defp status_for(nil, nil), do: "captured"
  defp status_for(_message_id, nil), do: "sent"
  defp status_for(_message_id, _error), do: "failed"

  defp recipients(%Swoosh.Email{} = email) do
    mailboxes(email.to, "to") ++ mailboxes(email.cc, "cc") ++ mailboxes(email.bcc, "bcc")
  end

  defp mailboxes(mailboxes, kind) do
    mailboxes
    |> List.wrap()
    |> Enum.map(fn mailbox ->
      %{kind: kind, address: mailbox_address(mailbox), name: mailbox_name(mailbox)}
    end)
  end

  defp mailbox_address({_name, address}), do: address
  defp mailbox_address(address) when is_binary(address), do: address
  defp mailbox_address(_), do: nil

  defp mailbox_name({name, _address}) when name not in [nil, ""], do: name
  defp mailbox_name(_), do: nil

  defp attachments(%Swoosh.Email{attachments: attachments}) do
    Enum.map(attachments, fn attachment ->
      %{
        filename: attachment.filename,
        content_type: attachment.content_type,
        size: attachment_size(attachment),
        disposition: to_string(attachment.type || :attachment)
      }
    end)
  end

  defp attachment_size(%{data: data}) when is_binary(data), do: byte_size(data)

  defp attachment_size(%{path: path}) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end

  defp attachment_size(_), do: nil

  defp extract_tags(%Swoosh.Email{provider_options: %{tags: tags}}) when is_list(tags) do
    Map.new(tags, fn
      %{name: name, value: value} -> {to_string(name), value}
      {name, value} -> {to_string(name), value}
    end)
  end

  defp extract_tags(_email), do: %{}

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_map(_), do: %{}

  # Swoosh.Adapters.AmazonSES / ExAwsAmazonSES: %{id: message_id, request_id: _}
  defp extract_message_id(%{id: message_id}) when is_binary(message_id), do: message_id

  # Raw SESv2 `send_email/3` response via the `aws` package: string-keyed,
  # PascalCase, straight off the wire.
  defp extract_message_id(%{"MessageId" => message_id}) when is_binary(message_id),
    do: message_id

  defp extract_message_id(_result), do: nil

  defp format_error(nil), do: nil
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)
end
