defmodule SquatchMail.SNS.Processor do
  @moduledoc """
  Orchestrates inbound SNS webhook delivery: token auth, signature
  verification, SES event normalization, persistence, and suppression rules.

  This is the single entry point the webhook controller calls with the raw
  request body and the `:token` path parameter. Every inbound payload is
  logged to `webhook_logs` (via `SquatchMail.Tracker.log_webhook/1`)
  regardless of outcome, so ingestion failures are always inspectable.

  ## SES event schema families

  SES publishes events in two shapes depending on how the host configured
  notifications:

    * **Event publishing** (configuration sets) - top-level `"eventType"`,
      e.g. `"Bounce"`, `"Send"`, `"Open"`.
    * **Legacy notifications** (identity-level feedback forwarding) -
      top-level `"notificationType"`, limited to `"Bounce"`, `"Complaint"`,
      `"Delivery"`.

  Both are normalized to the same lowercase `event_type` vocabulary before
  reaching `SquatchMail.Tracker.record_event/1`.

  ## Idempotency

  SNS is at-least-once delivery and retries on non-2xx responses, so the same
  SES event can arrive more than once. Events are deduped on
  `(message_id, event_type, recipient, occurred_at)` via an application-level
  existence check immediately before insert. This is a check-then-insert, not
  a database constraint, so there is a race window between two concurrent
  deliveries of the same retried event; a unique index would close it fully
  but requires a migration version bump, which is out of scope here. Given
  SNS retries are seconds-to-minutes apart in practice (not concurrent), this
  tradeoff is acceptable for now - noted so a future migration can add the
  constraint.
  """

  require Logger

  import Ecto.Query

  alias SquatchMail.{Config, EmailEvent, Source, Tracker}
  alias SquatchMail.SNS.MessageVerifier

  @soft_bounce_ttl_days 14

  @type outcome :: :processed | :ignored
  @type reason :: :invalid_token | :invalid_json | :signature_invalid | term()

  @doc """
  Processes a raw inbound webhook request body for the source identified by
  `token` (the path token, `SquatchMail.Source.webhook_token`).

  Returns `{:ok, :processed}` for messages that resulted in stored events,
  confirmed subscriptions, etc; `{:ok, :ignored}` for messages intentionally
  not acted on (e.g. `UnsubscribeConfirmation`, unknown event types);
  `{:error, reason}` otherwise. Every call logs to `webhook_logs`, including
  on error paths that occur before a `Source` can even be resolved.
  """
  @spec process(String.t(), String.t()) :: {:ok, outcome()} | {:error, reason()}
  def process(raw_body, token) when is_binary(raw_body) and is_binary(token) do
    with {:ok, source} <- find_source_by_token(token),
         {:ok, message} <- parse_json(raw_body) do
      handle_message(source, message)
    else
      {:error, :invalid_token} = error ->
        log_webhook(%{status: "failed", error: "invalid webhook token"})
        error

      {:error, :invalid_json} = error ->
        log_webhook(%{status: "failed", error: "invalid JSON body"})
        error
    end
  end

  ## ---------------------------------------------------------------------------
  ## Token lookup + JSON parsing
  ## ---------------------------------------------------------------------------

  defp find_source_by_token(token) do
    repo = Config.repo()

    repo.all(from(s in Source, select: {s.id, s.webhook_token}))
    |> Enum.find(fn {_id, source_token} -> constant_time_eq(source_token, token) end)
    |> case do
      {id, _token} -> {:ok, repo.get!(Source, id)}
      nil -> {:error, :invalid_token}
    end
  end

  # Constant-time comparison so token lookup doesn't leak timing information
  # about how many characters matched. Uses :crypto.hash to normalize length
  # before comparison since Plug.Crypto isn't a dependency here.
  defp constant_time_eq(a, b) when is_binary(a) and is_binary(b) do
    :crypto.hash(:sha256, a) == :crypto.hash(:sha256, b) and byte_size(a) == byte_size(b)
  end

  defp constant_time_eq(_a, _b), do: false

  defp parse_json(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  ## ---------------------------------------------------------------------------
  ## Dispatch by SNS message Type
  ## ---------------------------------------------------------------------------

  defp handle_message(source, %{"Type" => "SubscriptionConfirmation"} = message) do
    process_with_logging(message, fn ->
      with :ok <- verify(message) do
        handle_subscription_confirmation(source, message)
      end
    end)
  end

  defp handle_message(source, %{"Type" => "UnsubscribeConfirmation"} = message) do
    process_with_logging(message, fn ->
      with :ok <- verify(message) do
        Logger.info(
          "SquatchMail.SNS.Processor: received UnsubscribeConfirmation for source " <>
            "#{source.id}, topic #{message["TopicArn"]} - ignoring."
        )

        {:ok, :ignored}
      end
    end)
  end

  defp handle_message(_source, %{"Type" => "Notification"} = message) do
    process_with_logging(message, fn ->
      with :ok <- verify(message),
           {:ok, ses_event} <- parse_ses_event(message["Message"]) do
        handle_ses_event(ses_event)
      end
    end)
  end

  defp handle_message(_source, message) do
    process_with_logging(message, fn ->
      {:error, {:unsupported_message_type, message["Type"]}}
    end)
  end

  # Wraps a message handler with a single webhook_logs write reflecting the
  # outcome: processed/ignored on success, failed (with error text) otherwise.
  defp process_with_logging(message, fun) do
    case fun.() do
      {:ok, outcome} ->
        log_webhook(%{
          message_type: message["Type"],
          status: to_string(outcome),
          payload: message
        })

        {:ok, outcome}

      {:error, reason} = error ->
        log_webhook(%{
          message_type: message["Type"],
          status: "failed",
          error: inspect(reason),
          payload: message
        })

        error
    end
  end

  defp verify(message) do
    case MessageVerifier.verify(message) do
      :ok -> :ok
      {:error, reason} -> {:error, {:signature_invalid, reason}}
    end
  end

  ## ---------------------------------------------------------------------------
  ## SubscriptionConfirmation
  ## ---------------------------------------------------------------------------

  defp handle_subscription_confirmation(source, message) do
    topic_arn = message["TopicArn"]
    subscribe_url = message["SubscribeURL"]

    with :ok <- validate_topic_arn(source, topic_arn),
         :ok <- confirm_subscription(subscribe_url) do
      Tracker.update_source(%{sns_topic_arn: topic_arn})
      {:ok, :processed}
    end
  end

  defp validate_topic_arn(%Source{sns_topic_arn: nil}, _incoming), do: :ok
  defp validate_topic_arn(%Source{sns_topic_arn: same}, same), do: :ok

  defp validate_topic_arn(%Source{sns_topic_arn: configured}, incoming) do
    {:error, {:topic_arn_mismatch, expected: configured, got: incoming}}
  end

  defp confirm_subscription(nil), do: {:error, :missing_subscribe_url}

  defp confirm_subscription(subscribe_url) do
    request = Finch.build(:get, subscribe_url)

    case Finch.request(request, SquatchMail.Finch) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Finch.Response{status: status}} -> {:error, {:subscribe_http_status, status}}
      {:error, reason} -> {:error, {:subscribe_request_failed, reason}}
    end
  end

  ## ---------------------------------------------------------------------------
  ## SES event normalization
  ## ---------------------------------------------------------------------------

  defp parse_ses_event(message) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_ses_event_json}
    end
  end

  defp parse_ses_event(_message), do: {:error, :missing_ses_event_message}

  defp handle_ses_event(ses_event) do
    case event_type(ses_event) do
      nil ->
        {:error,
         {:unrecognized_ses_event, Map.take(ses_event, ["eventType", "notificationType"])}}

      type ->
        mail = Map.get(ses_event, "mail", %{})
        message_id = Map.get(mail, "messageId")

        events = build_event_attrs(type, ses_event, mail, message_id)

        with :ok <- record_all(events) do
          apply_suppression_rules(type, ses_event)
          {:ok, :processed}
        end
    end
  end

  # `eventType` (event publishing) takes precedence; falls back to the legacy
  # `notificationType` field. Both are lowercased to match Tracker's
  # vocabulary (`bounce`, `complaint`, `delivery`, ...). "Rendering Failure"
  # (with a space, event-publishing only) normalizes to `renderingfailure`.
  defp event_type(%{"eventType" => type}) when is_binary(type) do
    type |> String.downcase() |> String.replace(" ", "")
  end

  defp event_type(%{"notificationType" => type}) when is_binary(type) do
    String.downcase(type)
  end

  defp event_type(_), do: nil

  defp record_all(events) do
    Enum.reduce_while(events, :ok, fn attrs, :ok ->
      case record_event_deduped(attrs) do
        {:ok, _event_or_skipped} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp record_event_deduped(attrs) do
    if duplicate_event?(attrs) do
      {:ok, :duplicate}
    else
      Tracker.record_event(attrs)
    end
  end

  # Application-level existence check for idempotency - see moduledoc for the
  # race-window tradeoff versus a unique index.
  defp duplicate_event?(%{
         message_id: message_id,
         event_type: event_type,
         recipient: recipient,
         occurred_at: occurred_at
       })
       when not is_nil(message_id) do
    query =
      from e in EmailEvent,
        where:
          e.message_id == ^message_id and e.event_type == ^event_type and
            e.occurred_at == ^occurred_at

    query =
      if is_nil(recipient),
        do: where(query, [e], is_nil(e.recipient)),
        else: where(query, [e], e.recipient == ^recipient)

    Config.repo().exists?(query)
  end

  defp duplicate_event?(_attrs), do: false

  # Builds one `Tracker.record_event/1` attrs map per recipient (bounce/
  # complaint/delivery can carry multiple recipients per SNS message; SES
  # does not batch different notification types together, but does batch
  # multiple recipients of the *same* type into one payload).
  defp build_event_attrs("bounce", ses_event, mail, message_id) do
    bounce = Map.get(ses_event, "bounce", %{})
    occurred_at = timestamp(bounce["timestamp"] || mail["timestamp"])

    for recipient <- Map.get(bounce, "bouncedRecipients", []) do
      %{
        event_type: "bounce",
        message_id: message_id,
        recipient: recipient["emailAddress"],
        occurred_at: occurred_at,
        payload: ses_event
      }
    end
  end

  defp build_event_attrs("complaint", ses_event, mail, message_id) do
    complaint = Map.get(ses_event, "complaint", %{})
    occurred_at = timestamp(complaint["timestamp"] || mail["timestamp"])

    for recipient <- Map.get(complaint, "complainedRecipients", []) do
      %{
        event_type: "complaint",
        message_id: message_id,
        recipient: recipient["emailAddress"],
        occurred_at: occurred_at,
        payload: ses_event
      }
    end
  end

  defp build_event_attrs("delivery", ses_event, mail, message_id) do
    delivery = Map.get(ses_event, "delivery", %{})
    occurred_at = timestamp(delivery["timestamp"] || mail["timestamp"])

    case Map.get(delivery, "recipients", []) do
      [] ->
        [
          %{
            event_type: "delivery",
            message_id: message_id,
            recipient: nil,
            occurred_at: occurred_at,
            payload: ses_event
          }
        ]

      recipients ->
        for recipient <- recipients do
          %{
            event_type: "delivery",
            message_id: message_id,
            recipient: recipient,
            occurred_at: occurred_at,
            payload: ses_event
          }
        end
    end
  end

  defp build_event_attrs("send", ses_event, mail, message_id) do
    [
      %{
        event_type: "send",
        message_id: message_id,
        recipient: List.first(Map.get(mail, "destination", [])),
        occurred_at: timestamp(mail["timestamp"]),
        payload: ses_event
      }
    ]
  end

  defp build_event_attrs("reject", ses_event, mail, message_id) do
    [
      %{
        event_type: "reject",
        message_id: message_id,
        recipient: List.first(Map.get(mail, "destination", [])),
        occurred_at: timestamp(mail["timestamp"]),
        payload: ses_event
      }
    ]
  end

  defp build_event_attrs("open", ses_event, mail, message_id) do
    open = Map.get(ses_event, "open", %{})

    [
      %{
        event_type: "open",
        message_id: message_id,
        recipient: List.first(Map.get(mail, "destination", [])),
        ip_address: open["ipAddress"],
        user_agent: open["userAgent"],
        occurred_at: timestamp(open["timestamp"] || mail["timestamp"]),
        payload: ses_event
      }
    ]
  end

  defp build_event_attrs("click", ses_event, mail, message_id) do
    click = Map.get(ses_event, "click", %{})

    [
      %{
        event_type: "click",
        message_id: message_id,
        recipient: List.first(Map.get(mail, "destination", [])),
        url: click["link"],
        ip_address: click["ipAddress"],
        user_agent: click["userAgent"],
        occurred_at: timestamp(click["timestamp"] || mail["timestamp"]),
        payload: ses_event
      }
    ]
  end

  defp build_event_attrs("renderingfailure", ses_event, mail, message_id) do
    [
      %{
        event_type: "renderingfailure",
        message_id: message_id,
        recipient: List.first(Map.get(mail, "destination", [])),
        occurred_at: timestamp(mail["timestamp"]),
        payload: ses_event
      }
    ]
  end

  defp build_event_attrs("deliverydelay", ses_event, mail, message_id) do
    delay = Map.get(ses_event, "deliveryDelay", %{})
    occurred_at = timestamp(delay["timestamp"] || mail["timestamp"])

    case Map.get(delay, "delayedRecipients", []) do
      [] ->
        [
          %{
            event_type: "deliverydelay",
            message_id: message_id,
            recipient: List.first(Map.get(mail, "destination", [])),
            occurred_at: occurred_at,
            payload: ses_event
          }
        ]

      recipients ->
        for recipient <- recipients do
          %{
            event_type: "deliverydelay",
            message_id: message_id,
            recipient: recipient["emailAddress"],
            occurred_at: occurred_at,
            payload: ses_event
          }
        end
    end
  end

  defp build_event_attrs("subscription", ses_event, mail, message_id) do
    subscription = Map.get(ses_event, "subscription", %{})

    [
      %{
        event_type: "subscription",
        message_id: message_id,
        recipient: List.first(Map.get(mail, "destination", [])),
        occurred_at: timestamp(subscription["timestamp"] || mail["timestamp"]),
        payload: ses_event
      }
    ]
  end

  # Unknown event type made it past `event_type/1` resolution (defensive;
  # `event_type/1` only returns types we recognize below, but new SES event
  # types may ship before we add explicit handling).
  defp build_event_attrs(type, ses_event, mail, message_id) do
    [
      %{
        event_type: type,
        message_id: message_id,
        recipient: List.first(Map.get(mail, "destination", [])),
        occurred_at: timestamp(mail["timestamp"]),
        payload: ses_event
      }
    ]
  end

  defp timestamp(nil), do: DateTime.utc_now()

  defp timestamp(iso8601) when is_binary(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _offset} -> dt
      {:error, _reason} -> DateTime.utc_now()
    end
  end

  ## ---------------------------------------------------------------------------
  ## Suppression rules
  ## ---------------------------------------------------------------------------

  defp apply_suppression_rules("bounce", ses_event) do
    bounce = Map.get(ses_event, "bounce", %{})
    bounce_type = Map.get(bounce, "bounceType")

    for recipient <- Map.get(bounce, "bouncedRecipients", []),
        address = recipient["emailAddress"],
        not is_nil(address) do
      suppress_for_bounce(address, bounce_type)
    end

    :ok
  end

  defp apply_suppression_rules("complaint", ses_event) do
    complaint = Map.get(ses_event, "complaint", %{})

    for recipient <- Map.get(complaint, "complainedRecipients", []),
        address = recipient["emailAddress"],
        not is_nil(address) do
      Tracker.suppress(%{address: address, reason: "complaint", event_type: "complaint"})
    end

    :ok
  end

  defp apply_suppression_rules(_type, _ses_event), do: :ok

  defp suppress_for_bounce(address, "Permanent") do
    Tracker.suppress(%{address: address, reason: "hard_bounce", event_type: "bounce"})
  end

  defp suppress_for_bounce(address, _transient_or_other) do
    expires_at = DateTime.add(DateTime.utc_now(), @soft_bounce_ttl_days * 86_400, :second)

    Tracker.suppress(%{
      address: address,
      reason: "soft_bounce",
      event_type: "bounce",
      expires_at: expires_at
    })
  end

  ## ---------------------------------------------------------------------------
  ## webhook_logs
  ## ---------------------------------------------------------------------------

  defp log_webhook(attrs) do
    attrs
    |> Map.put_new(:provider, "ses")
    |> Map.put_new(:status, "received")
    |> Tracker.log_webhook()
  end
end
