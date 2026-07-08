defmodule SquatchMail.Capture do
  @moduledoc """
  Observes every `Swoosh.Mailer.deliver/2` and `deliver_many/2` call in the
  host application via `:telemetry`, with zero changes to the host's mailer
  or adapter.

  `Swoosh.Mailer` wraps each send in `:telemetry.span/3`, emitting
  `[:swoosh, :deliver | :deliver_many, :start | :stop | :exception]`. This
  module attaches to `:stop` and `:exception` only — never `:start`, since
  there's nothing to persist until a send has actually finished — and
  records the outcome through `SquatchMail.Capture.Recorder`.

  ## Design constraints

  Telemetry handlers run **synchronously in the caller's process** — the
  same process that just called `Mailer.deliver/2`. This module therefore:

    * never raises: every step is wrapped and logged on failure rather than
      propagated, so a SquatchMail bug can never break the host's mail
      sending;
    * never blocks the caller: the handler only builds attrs and hands them
      to `SquatchMail.Capture.Recorder.record/1` (a `GenServer.cast/2`),
      returning immediately regardless of how long the actual database write
      takes, or whether the queue is full and the attrs get dropped.

  ## Adapter result normalization

  The `result` telemetry metadata is adapter-specific. This module
  recognizes:

    * `Swoosh.Adapters.AmazonSES` and `Swoosh.Adapters.ExAwsAmazonSES`
      (which delegates straight to `AmazonSES`, producing the same shape):
      `%{id: message_id, request_id: request_id}` — atom-keyed.
    * Raw `AWS.SESv2.send_email/3` responses (for hosts using a custom
      adapter built directly on the `aws` package): `%{"MessageId" =>
      message_id}` — string-keyed, PascalCase, straight off the wire.

  Any other adapter's result is still recorded — just without a
  `message_id`, which means SES event ingestion won't be able to correlate
  delivery/bounce events back to it later. Unrecognized shapes are never
  treated as an error.

  ## Configuration

  See `SquatchMail.Config` for `:enabled` and the nested `:capture` options
  (`:store_html`, `:store_text`, `:sample_rate`, `:max_queue`).
  """

  require Logger

  alias SquatchMail.Config

  @handler_id "squatch-mail-capture"

  @events [
    [:swoosh, :deliver, :stop],
    [:swoosh, :deliver, :exception],
    [:swoosh, :deliver_many, :stop],
    [:swoosh, :deliver_many, :exception]
  ]

  @doc """
  Attaches the capture handler.

  No-ops (logging nothing, doing nothing) when Swoosh isn't loaded — it's an
  optional dependency, and a host observing nothing through it is a valid
  configuration, not an error. Safe to call more than once: re-attaching
  detaches the previous handler first rather than erroring or double-firing.
  """
  @spec attach() :: :ok
  def attach do
    if Code.ensure_loaded?(Swoosh) do
      :telemetry.detach(@handler_id)
      :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
    else
      :ok
    end
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
    guarded(fn -> maybe_capture_single(metadata) end)
  end

  def handle_event([:swoosh, :deliver, :exception], _measurements, metadata, _config) do
    guarded(fn -> maybe_capture_single_exception(metadata) end)
  end

  def handle_event([:swoosh, :deliver_many, :stop], _measurements, metadata, _config) do
    guarded(fn -> maybe_capture_many(metadata) end)
  end

  def handle_event([:swoosh, :deliver_many, :exception], _measurements, metadata, _config) do
    guarded(fn -> maybe_capture_many_exception(metadata) end)
  end

  defp guarded(fun) do
    fun.()
  rescue
    error ->
      Logger.warning(
        "SquatchMail.Capture failed handling a telemetry event: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )
  end

  defp maybe_capture_single(metadata) do
    if capture?() do
      capture_single(metadata)
    end
  end

  defp maybe_capture_single_exception(metadata) do
    if capture?() do
      capture_single_exception(metadata)
    end
  end

  defp maybe_capture_many(metadata) do
    if capture?() do
      capture_many(metadata)
    end
  end

  defp maybe_capture_many_exception(metadata) do
    if capture?() do
      capture_many_exception(metadata)
    end
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

    email
    |> email_attrs(mailer, result, error)
    |> SquatchMail.Capture.Recorder.record()
  end

  defp capture_single_exception(%{email: email, mailer: mailer, reason: reason}) do
    email
    |> email_attrs(mailer, nil, reason)
    |> SquatchMail.Capture.Recorder.record()
  end

  defp capture_many(%{emails: emails, mailer: mailer} = metadata) do
    result = Map.get(metadata, :result)
    error = Map.get(metadata, :error)

    emails
    |> Enum.with_index()
    |> Enum.each(fn {email, index} ->
      email
      |> email_attrs(mailer, result_for_index(result, index), error)
      |> SquatchMail.Capture.Recorder.record()
    end)
  end

  defp capture_many_exception(%{emails: emails, mailer: mailer, reason: reason}) do
    Enum.each(emails, fn email ->
      email
      |> email_attrs(mailer, nil, reason)
      |> SquatchMail.Capture.Recorder.record()
    end)
  end

  # `deliver_many/2` results are adapter-specific about whether they return
  # one result per email or a single aggregate result; we only know how to
  # line up a list positionally. Anything else falls back to "no per-email
  # result", which just means no message_id gets recorded for these emails.
  defp result_for_index(results, index) when is_list(results), do: Enum.at(results, index)
  defp result_for_index(_results, _index), do: nil

  defp email_attrs(email, mailer, result, error) do
    message_id = extract_message_id(result)

    %{
      status: status_for(message_id, error),
      from_email: mailbox_address(email.from),
      from_name: mailbox_name(email.from),
      subject: email.subject,
      html_body: maybe_body(email.html_body, Config.store_html?()),
      text_body: maybe_body(email.text_body, Config.store_text?()),
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

  defp maybe_body(_body, false), do: nil
  defp maybe_body(body, true), do: body

  defp status_for(nil, nil), do: "captured"
  defp status_for(_message_id, nil), do: "sent"
  # A blocked SquatchMail.Adapters.Watchtower send surfaces its
  # SquatchMail.Guard block reason as the telemetry :error, so it's recorded
  # as "suppressed" rather than lumped in with genuine adapter failures.
  defp status_for(_message_id, {:suppressed, _addresses}), do: "suppressed"
  defp status_for(_message_id, :complaint_rate_paused), do: "suppressed"
  defp status_for(_message_id, _error), do: "failed"

  defp recipients(email) do
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

  defp attachments(%{attachments: attachments}) do
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

  defp extract_tags(%{provider_options: %{tags: tags}}) when is_list(tags) do
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
