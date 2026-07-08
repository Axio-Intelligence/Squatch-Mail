defmodule SquatchMail.SNS.MessageVerifierTest do
  use ExUnit.Case, async: false

  alias SquatchMail.SNS.MessageVerifier
  alias SquatchMail.Test.SNSSigning

  setup_all do
    keypair = SNSSigning.generate_keypair!()
    {:ok, keypair: keypair}
  end

  setup %{keypair: keypair} do
    SNSSigning.stub_cert_fetcher(keypair.cert_url, keypair.cert_pem)
    :ok
  end

  defp notification_envelope(overrides \\ %{}) do
    %{
      "Type" => "Notification",
      "MessageId" => "22b80b92-fdea-4c2c-8f9d-bdfb0c7bf324",
      "TopicArn" => "arn:aws:sns:us-east-1:123456789012:squatch-mail-ses-events",
      "Subject" => "Amazon SES Email Event Notification",
      "Message" => ~s({"eventType":"Send"}),
      "Timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
    |> Map.merge(overrides)
  end

  defp confirmation_envelope(overrides \\ %{}) do
    %{
      "Type" => "SubscriptionConfirmation",
      "MessageId" => "165545c9-2a5c-472c-8df2-7ff2be2b3b1b",
      "Token" => "sometoken",
      "TopicArn" => "arn:aws:sns:us-east-1:123456789012:squatch-mail-ses-events",
      "Message" => "You have chosen to subscribe...",
      "SubscribeURL" =>
        "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription&Token=sometoken",
      "Timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
    |> Map.merge(overrides)
  end

  describe "SignatureVersion 1 (SHA1withRSA)" do
    test "verifies a correctly signed Notification", %{keypair: keypair} do
      envelope = notification_envelope() |> SNSSigning.sign(keypair, "1")
      assert :ok = MessageVerifier.verify(envelope)
    end

    test "verifies a correctly signed SubscriptionConfirmation", %{keypair: keypair} do
      envelope = confirmation_envelope() |> SNSSigning.sign(keypair, "1")
      assert :ok = MessageVerifier.verify(envelope)
    end
  end

  describe "SignatureVersion 2 (SHA256withRSA)" do
    test "verifies a correctly signed Notification", %{keypair: keypair} do
      envelope = notification_envelope() |> SNSSigning.sign(keypair, "2")
      assert :ok = MessageVerifier.verify(envelope)
    end

    test "verifies a correctly signed UnsubscribeConfirmation", %{keypair: keypair} do
      envelope =
        confirmation_envelope(%{"Type" => "UnsubscribeConfirmation"})
        |> SNSSigning.sign(keypair, "2")

      assert :ok = MessageVerifier.verify(envelope)
    end

    test "Notification without a Subject still verifies (optional field omitted)", %{
      keypair: keypair
    } do
      envelope =
        notification_envelope()
        |> Map.delete("Subject")
        |> SNSSigning.sign(keypair, "2")

      assert :ok = MessageVerifier.verify(envelope)
    end
  end

  describe "tampering" do
    test "rejects a Notification whose Message was altered after signing", %{keypair: keypair} do
      envelope = notification_envelope() |> SNSSigning.sign(keypair, "2")
      tampered = Map.put(envelope, "Message", ~s({"eventType":"Bounce"}))

      assert {:error, :signature_mismatch} = MessageVerifier.verify(tampered)
    end

    test "rejects when the Signature itself is altered", %{keypair: keypair} do
      envelope = notification_envelope() |> SNSSigning.sign(keypair, "2")
      tampered = Map.update!(envelope, "Signature", &(String.slice(&1, 0..-3//1) <> "xx=="))

      assert {:error, _reason} = MessageVerifier.verify(tampered)
    end

    test "rejects a Subject added after signing (Subject was omitted from string-to-sign)", %{
      keypair: keypair
    } do
      envelope =
        notification_envelope()
        |> Map.delete("Subject")
        |> SNSSigning.sign(keypair, "2")

      tampered = Map.put(envelope, "Subject", "injected subject")
      assert {:error, :signature_mismatch} = MessageVerifier.verify(tampered)
    end
  end

  describe "SigningCertURL validation (checked before any fetch)" do
    test "rejects a non-https cert URL without attempting a fetch", %{keypair: keypair} do
      envelope =
        notification_envelope()
        |> SNSSigning.sign(keypair, "2")
        |> Map.put("SigningCertURL", "http://sns.us-east-1.amazonaws.com/cert.pem")

      Application.put_env(:squatch_mail, :sns_cert_fetcher, fn _url ->
        flunk("cert fetch should not have been attempted")
      end)

      assert {:error, :signing_cert_url_not_https} = MessageVerifier.verify(envelope)
    end

    test "rejects a cert URL on the wrong host without attempting a fetch", %{keypair: keypair} do
      envelope =
        notification_envelope()
        |> SNSSigning.sign(keypair, "2")
        |> Map.put("SigningCertURL", "https://evil.example.com/SimpleNotificationService.pem")

      Application.put_env(:squatch_mail, :sns_cert_fetcher, fn _url ->
        flunk("cert fetch should not have been attempted")
      end)

      assert {:error, :signing_cert_url_bad_host} = MessageVerifier.verify(envelope)
    end

    test "rejects a cert URL that looks like the right host but isn't a real subdomain match", %{
      keypair: keypair
    } do
      envelope =
        notification_envelope()
        |> SNSSigning.sign(keypair, "2")
        |> Map.put("SigningCertURL", "https://sns.us-east-1.amazonaws.com.evil.com/x.pem")

      assert {:error, :signing_cert_url_bad_host} = MessageVerifier.verify(envelope)
    end

    test "rejects a cert URL not ending in .pem", %{keypair: keypair} do
      envelope =
        notification_envelope()
        |> SNSSigning.sign(keypair, "2")
        |> Map.put("SigningCertURL", "https://sns.us-east-1.amazonaws.com/cert.txt")

      assert {:error, :signing_cert_url_bad_path} = MessageVerifier.verify(envelope)
    end

    test "accepts a China-region SNS host suffix (.amazonaws.com.cn)" do
      envelope = %{
        "Type" => "Notification",
        "MessageId" => "id",
        "TopicArn" => "arn",
        "Message" => "msg",
        "Timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "SignatureVersion" => "2",
        "Signature" => Base.encode64("irrelevant-cert-fetch-will-fail-first"),
        "SigningCertURL" => "https://sns.cn-north-1.amazonaws.com.cn/cert.pem"
      }

      Application.put_env(:squatch_mail, :sns_cert_fetcher, fn url ->
        send(self(), {:fetch_attempted, url})
        {:error, :not_found}
      end)

      MessageVerifier.verify(envelope)
      assert_received {:fetch_attempted, "https://sns.cn-north-1.amazonaws.com.cn/cert.pem"}
    end
  end

  describe "missing/invalid fields" do
    test "errors on missing required field" do
      envelope = notification_envelope() |> Map.delete("TopicArn")

      assert {:error, {:missing_fields, missing}} = MessageVerifier.verify(envelope)
      assert "TopicArn" in missing
    end

    test "errors on unsupported SignatureVersion", %{keypair: keypair} do
      envelope =
        notification_envelope()
        |> SNSSigning.sign(keypair, "2")
        |> Map.put("SignatureVersion", "3")

      assert {:error, {:unsupported_signature_version, "3"}} = MessageVerifier.verify(envelope)
    end

    test "errors on unsupported message Type" do
      envelope = notification_envelope(%{"Type" => "SomethingElse"})
      assert {:error, {:unsupported_type, "SomethingElse"}} = MessageVerifier.verify(envelope)
    end
  end

  describe "cert timestamp validity" do
    test "rejects when the message Timestamp predates the certificate's validity window" do
      keypair = SNSSigning.generate_keypair!()
      SNSSigning.stub_cert_fetcher(keypair.cert_url, keypair.cert_pem)

      envelope =
        notification_envelope(%{"Timestamp" => "1999-01-01T00:00:00.000Z"})
        |> SNSSigning.sign(keypair, "2")

      assert {:error, :timestamp_before_cert_validity} = MessageVerifier.verify(envelope)
    end
  end

  describe "verify_sns_signatures: false escape hatch" do
    test "accepts anything, unverified, when disabled" do
      Application.put_env(:squatch_mail, :verify_sns_signatures, false)

      on_exit(fn -> Application.delete_env(:squatch_mail, :verify_sns_signatures) end)

      envelope = %{"Type" => "Notification", "MessageId" => "whatever, unsigned"}
      assert :ok = MessageVerifier.verify(envelope)
    end
  end

  describe "cert caching" do
    test "caches the fetched cert so a second verification does not refetch", %{
      keypair: keypair
    } do
      envelope1 = notification_envelope() |> SNSSigning.sign(keypair, "2")

      envelope2 =
        notification_envelope(%{"MessageId" => "different-id"}) |> SNSSigning.sign(keypair, "2")

      test_pid = self()

      Application.put_env(:squatch_mail, :sns_cert_fetcher, fn _url ->
        send(test_pid, :fetch_called)
        {:ok, keypair.cert_pem}
      end)

      assert :ok = MessageVerifier.verify(envelope1)
      assert_received :fetch_called
      refute_received :fetch_called

      assert :ok = MessageVerifier.verify(envelope2)
      refute_received :fetch_called
    end
  end
end
