defmodule SquatchMail.SNS.ProcessorTest do
  use SquatchMail.DataCase, async: false

  import Ecto.Query

  alias SquatchMail.{EmailEvent, Source, Suppression, Tracker, WebhookLog}
  alias SquatchMail.SNS.Processor

  @fixtures_dir Path.join([__DIR__, "..", "..", "support", "fixtures", "sns"])

  setup do
    Application.put_env(:squatch_mail, :verify_sns_signatures, false)
    on_exit(fn -> Application.delete_env(:squatch_mail, :verify_sns_signatures) end)

    source = Tracker.get_or_create_source()
    {:ok, source: source}
  end

  defp fixture(name) do
    Path.join(@fixtures_dir, name) |> File.read!()
  end

  defp notification_envelope(ses_event_json, overrides \\ %{}) do
    %{
      "Type" => "Notification",
      "MessageId" => Ecto.UUID.generate(),
      "TopicArn" => "arn:aws:sns:us-east-1:123456789012:squatch-mail-ses-events",
      "Subject" => "Amazon SES Email Event Notification",
      "Message" => ses_event_json,
      "Timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "SignatureVersion" => "1",
      "Signature" => "unused-because-verification-is-disabled",
      "SigningCertURL" => "https://sns.us-east-1.amazonaws.com/cert.pem"
    }
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  describe "invalid token" do
    test "returns {:error, :invalid_token} for an unknown token", %{source: _source} do
      assert {:error, :invalid_token} = Processor.process("{}", "not-a-real-token")
    end

    test "logs a failed webhook entry for an invalid token" do
      Processor.process("{}", "bogus-token")

      log = Repo.one!(from w in WebhookLog, order_by: [desc: w.id], limit: 1)
      assert log.status == "failed"
      assert log.error =~ "invalid webhook token"
    end
  end

  describe "invalid JSON" do
    test "returns {:error, :invalid_json} for malformed body", %{source: source} do
      assert {:error, :invalid_json} = Processor.process("{not json", source.webhook_token)
    end
  end

  describe "bounce event (event publishing / eventType)" do
    test "permanent bounce creates an event and a hard_bounce suppression with no expiry", %{
      source: source
    } do
      body = notification_envelope(fixture("ses_bounce_permanent.json"))
      assert {:ok, :processed} = Processor.process(body, source.webhook_token)

      event = Repo.one!(from e in EmailEvent, where: e.event_type == "bounce")
      assert event.recipient == "recipient@example.com"
      assert event.message_id == "EXAMPLE7c191be45-e9aedb9a-02f9-4d12-a87d-dd0099a07f8a-000000"
      assert DateTime.compare(event.occurred_at, ~U[2017-08-05 00:41:02.669Z]) == :eq

      suppression = Repo.get_by!(Suppression, address: "recipient@example.com")
      assert suppression.reason == "hard_bounce"
      assert suppression.expires_at == nil

      log = Repo.one!(from w in WebhookLog, order_by: [desc: w.id], limit: 1)
      assert log.status == "processed"
      assert log.message_type == "Notification"
    end

    test "transient bounce creates a soft_bounce suppression expiring in ~14 days", %{
      source: source
    } do
      body = notification_envelope(fixture("ses_bounce_transient.json"))
      assert {:ok, :processed} = Processor.process(body, source.webhook_token)

      suppression = Repo.get_by!(Suppression, address: "recipient2@example.com")
      assert suppression.reason == "soft_bounce"
      assert suppression.expires_at != nil

      days_until_expiry = DateTime.diff(suppression.expires_at, DateTime.utc_now(), :day)
      assert days_until_expiry in 13..14
    end
  end

  describe "complaint event" do
    test "creates an event and a permanent complaint suppression", %{source: source} do
      body = notification_envelope(fixture("ses_complaint.json"))
      assert {:ok, :processed} = Processor.process(body, source.webhook_token)

      event = Repo.one!(from e in EmailEvent, where: e.event_type == "complaint")
      assert event.recipient == "recipient@example.com"

      suppression = Repo.get_by!(Suppression, address: "recipient@example.com")
      assert suppression.reason == "complaint"
      assert suppression.expires_at == nil
    end
  end

  describe "delivery event" do
    test "creates a delivery event per recipient, no suppression", %{source: source} do
      body = notification_envelope(fixture("ses_delivery.json"))
      assert {:ok, :processed} = Processor.process(body, source.webhook_token)

      event = Repo.one!(from e in EmailEvent, where: e.event_type == "delivery")
      assert event.recipient == "recipient@example.com"
      assert Repo.aggregate(Suppression, :count) == 0
    end
  end

  describe "send event" do
    test "creates a send event", %{source: source} do
      body = notification_envelope(fixture("ses_send.json"))
      assert {:ok, :processed} = Processor.process(body, source.webhook_token)

      event = Repo.one!(from e in EmailEvent, where: e.event_type == "send")
      assert event.recipient == "recipient@example.com"
    end
  end

  describe "open event" do
    test "captures ip_address and user_agent", %{source: source} do
      body = notification_envelope(fixture("ses_open.json"))
      assert {:ok, :processed} = Processor.process(body, source.webhook_token)

      event = Repo.one!(from e in EmailEvent, where: e.event_type == "open")
      assert event.ip_address == "192.0.2.1"
      assert event.user_agent =~ "iPhone"
      assert DateTime.compare(event.occurred_at, ~U[2017-08-09 22:00:19.652Z]) == :eq
    end
  end

  describe "click event" do
    test "captures url, ip_address, and user_agent", %{source: source} do
      body = notification_envelope(fixture("ses_click.json"))
      assert {:ok, :processed} = Processor.process(body, source.webhook_token)

      event = Repo.one!(from e in EmailEvent, where: e.event_type == "click")

      assert event.url ==
               "http://docs.aws.amazon.com/ses/latest/DeveloperGuide/send-email-smtp.html"

      assert event.ip_address == "192.0.2.1"
      assert event.user_agent =~ "Chrome"
    end
  end

  describe "deliverydelay event" do
    test "creates one event per delayed recipient", %{source: source} do
      body = notification_envelope(fixture("ses_deliverydelay.json"))
      assert {:ok, :processed} = Processor.process(body, source.webhook_token)

      event = Repo.one!(from e in EmailEvent, where: e.event_type == "deliverydelay")
      assert event.recipient == "recipient@example.com"
    end
  end

  describe "legacy notificationType payloads" do
    test "legacy bounce (notificationType field) normalizes the same as eventType", %{
      source: source
    } do
      body = notification_envelope(fixture("legacy_bounce.json"))
      assert {:ok, :processed} = Processor.process(body, source.webhook_token)

      events = Repo.all(from e in EmailEvent, where: e.event_type == "bounce")
      assert length(events) == 2
      addresses = Enum.map(events, & &1.recipient) |> Enum.sort()
      assert addresses == ["jane@example.com", "richard@example.com"]

      assert Repo.get_by!(Suppression, address: "jane@example.com").reason == "hard_bounce"
      assert Repo.get_by!(Suppression, address: "richard@example.com").reason == "hard_bounce"
    end
  end

  describe "idempotency / dedupe on double delivery" do
    test "processing the identical bounce notification twice records only one event", %{
      source: source
    } do
      body = notification_envelope(fixture("ses_bounce_permanent.json"))

      assert {:ok, :processed} = Processor.process(body, source.webhook_token)
      assert {:ok, :processed} = Processor.process(body, source.webhook_token)

      count =
        Repo.aggregate(
          from(e in EmailEvent, where: e.event_type == "bounce"),
          :count
        )

      assert count == 1
    end

    test "webhook_logs still gets an entry for each delivery, even when the event is deduped", %{
      source: source
    } do
      body = notification_envelope(fixture("ses_bounce_permanent.json"))

      Processor.process(body, source.webhook_token)
      Processor.process(body, source.webhook_token)

      count = Repo.aggregate(WebhookLog, :count)
      assert count == 2
    end
  end

  describe "SubscriptionConfirmation" do
    setup do
      port = SquatchMail.Test.SubscribeTestEndpoint.start_link(self())
      {:ok, subscribe_url: "http://127.0.0.1:#{port}/confirm"}
    end

    test "GETs the SubscribeURL and stores the TopicArn on the source", %{
      source: source,
      subscribe_url: subscribe_url
    } do
      topic_arn = "arn:aws:sns:us-east-1:123456789012:squatch-mail-ses-events"

      envelope =
        %{
          "Type" => "SubscriptionConfirmation",
          "MessageId" => Ecto.UUID.generate(),
          "Token" => "abc123",
          "TopicArn" => topic_arn,
          "Message" => "You have chosen to subscribe...",
          "SubscribeURL" => subscribe_url,
          "Timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "SignatureVersion" => "1",
          "Signature" => "unused",
          "SigningCertURL" => "https://sns.us-east-1.amazonaws.com/cert.pem"
        }
        |> Jason.encode!()

      assert {:ok, :processed} = Processor.process(envelope, source.webhook_token)
      assert_received {:subscribe_request, "/confirm"}

      updated_source = Repo.get!(Source, source.id)
      assert updated_source.sns_topic_arn == topic_arn
    end

    test "rejects when TopicArn mismatches an already-configured source, without GETing SubscribeURL",
         %{source: source, subscribe_url: subscribe_url} do
      Tracker.update_source(%{
        sns_topic_arn: "arn:aws:sns:us-east-1:123456789012:some-other-topic"
      })

      envelope =
        %{
          "Type" => "SubscriptionConfirmation",
          "MessageId" => Ecto.UUID.generate(),
          "Token" => "abc123",
          "TopicArn" => "arn:aws:sns:us-east-1:123456789012:squatch-mail-ses-events",
          "Message" => "You have chosen to subscribe...",
          "SubscribeURL" => subscribe_url,
          "Timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "SignatureVersion" => "1",
          "Signature" => "unused",
          "SigningCertURL" => "https://sns.us-east-1.amazonaws.com/cert.pem"
        }
        |> Jason.encode!()

      assert {:error, {:topic_arn_mismatch, _}} =
               Processor.process(envelope, source.webhook_token)

      refute_received {:subscribe_request, _}
    end
  end

  describe "UnsubscribeConfirmation" do
    test "is logged and ignored", %{source: source} do
      envelope =
        %{
          "Type" => "UnsubscribeConfirmation",
          "MessageId" => Ecto.UUID.generate(),
          "Token" => "abc123",
          "TopicArn" => "arn:aws:sns:us-east-1:123456789012:squatch-mail-ses-events",
          "Message" => "You have chosen to deactivate...",
          "SubscribeURL" => "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription",
          "Timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "SignatureVersion" => "1",
          "Signature" => "unused",
          "SigningCertURL" => "https://sns.us-east-1.amazonaws.com/cert.pem"
        }
        |> Jason.encode!()

      assert {:ok, :ignored} = Processor.process(envelope, source.webhook_token)

      log = Repo.one!(from w in WebhookLog, order_by: [desc: w.id], limit: 1)
      assert log.status == "ignored"
    end
  end
end
