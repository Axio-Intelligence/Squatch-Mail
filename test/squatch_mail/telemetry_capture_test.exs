defmodule SquatchMail.TelemetryCaptureTest do
  # Persistence happens on a separately-spawned task, off the process that
  # fires the telemetry event, so the sandbox connection needs to be shared
  # rather than owned exclusively by this test's process.
  use SquatchMail.DataCase, async: false

  alias SquatchMail.{TelemetryCapture, Tracker}

  setup do
    # The application's own SquatchMail.Application.start/2 already attached
    # the real handler for the whole test run; re-attaching here is harmless
    # (attach/0 detaches first) and keeps this test file meaningful even if
    # run in isolation.
    TelemetryCapture.attach()
    on_exit(fn -> TelemetryCapture.attach() end)
    :ok
  end

  defp email(opts \\ []) do
    Swoosh.Email.new(
      Keyword.merge(
        [
          from: {"Sender", "sender@example.com"},
          to: {"Recipient", "recipient@example.com"},
          subject: "Hello",
          html_body: "<p>Hi</p>",
          text_body: "Hi"
        ],
        opts
      )
    )
  end

  # Persistence runs on a supervised Task; give it a moment and poll rather
  # than assume a fixed sleep is enough (or too long) on a loaded CI box.
  defp eventually(fun, attempts \\ 20) do
    case fun.() do
      nil when attempts > 0 ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      result ->
        result
    end
  end

  defp find_by_message_id(message_id) do
    eventually(fn ->
      Tracker.list_emails(%{limit: 1000})
      |> Enum.find(&(&1.message_id == message_id))
    end)
  end

  describe "deliver :stop" do
    test "records a sent email with the AmazonSES adapter's result shape" do
      message_id = "ses-#{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:swoosh, :deliver, :stop],
        %{duration: 1},
        %{
          email: email(),
          mailer: MyTestApp.Mailer,
          config: [adapter: Swoosh.Adapters.AmazonSES],
          result: %{id: message_id, request_id: "req-1"}
        }
      )

      recorded = find_by_message_id(message_id)

      assert recorded
      assert recorded.status == "sent"
      assert recorded.from_email == "sender@example.com"
      assert recorded.from_name == "Sender"
      assert recorded.subject == "Hello"
      assert recorded.mailer == "MyTestApp.Mailer"
      assert length(recorded.recipients) == 1
    end

    test "records a sent email with a raw SESv2 (PascalCase string-keyed) result shape" do
      message_id = "sesv2-#{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:swoosh, :deliver, :stop],
        %{duration: 1},
        %{
          email: email(),
          mailer: MyTestApp.Mailer,
          config: [],
          result: %{"MessageId" => message_id}
        }
      )

      recorded = find_by_message_id(message_id)
      assert recorded
      assert recorded.status == "sent"
    end

    test "records a failed send when metadata carries an :error" do
      email = email(subject: "Failure case #{System.unique_integer([:positive])}")

      :telemetry.execute(
        [:swoosh, :deliver, :stop],
        %{duration: 1},
        %{
          email: email,
          mailer: MyTestApp.Mailer,
          config: [],
          error: :timeout
        }
      )

      recorded =
        eventually(fn ->
          Tracker.list_emails(%{limit: 1000})
          |> Enum.find(&(&1.subject == email.subject))
        end)

      assert recorded
      assert recorded.status == "failed"
      assert recorded.error =~ "timeout"
      assert recorded.message_id == nil
    end

    test "records an unrecognized result shape without a message_id or error" do
      email = email(subject: "Unknown adapter #{System.unique_integer([:positive])}")

      :telemetry.execute(
        [:swoosh, :deliver, :stop],
        %{duration: 1},
        %{email: email, mailer: MyTestApp.Mailer, config: [], result: :ok}
      )

      recorded =
        eventually(fn ->
          Tracker.list_emails(%{limit: 1000})
          |> Enum.find(&(&1.subject == email.subject))
        end)

      assert recorded
      assert recorded.status == "captured"
      assert recorded.message_id == nil
    end

    test "captures attachments and cc/bcc recipients" do
      message_id = "attach-#{System.unique_integer([:positive])}"

      attached_email =
        email()
        |> Swoosh.Email.cc({"CC Person", "cc@example.com"})
        |> Swoosh.Email.bcc("bcc@example.com")
        |> Swoosh.Email.attachment(Swoosh.Attachment.new({:data, "hi"}, filename: "note.txt"))

      :telemetry.execute(
        [:swoosh, :deliver, :stop],
        %{duration: 1},
        %{
          email: attached_email,
          mailer: MyTestApp.Mailer,
          config: [],
          result: %{id: message_id}
        }
      )

      recorded = find_by_message_id(message_id)
      assert recorded
      assert recorded.has_attachments == true
      assert recorded.attachments_count == 1

      full = Tracker.get_email!(recorded.public_id)
      assert Enum.any?(full.attachments, &(&1.filename == "note.txt"))
      assert Enum.any?(full.recipients, &(&1.address == "cc@example.com" and &1.kind == "cc"))
      assert Enum.any?(full.recipients, &(&1.address == "bcc@example.com" and &1.kind == "bcc"))
    end
  end

  describe "deliver :exception" do
    test "records a failed email" do
      subject = "Exception case #{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:swoosh, :deliver, :exception],
        %{duration: 1},
        %{
          email: email(subject: subject),
          mailer: MyTestApp.Mailer,
          config: [],
          kind: :error,
          reason: %RuntimeError{message: "adapter blew up"},
          stacktrace: []
        }
      )

      recorded =
        eventually(fn ->
          Tracker.list_emails(%{limit: 1000})
          |> Enum.find(&(&1.subject == subject))
        end)

      assert recorded
      assert recorded.status == "failed"
      assert recorded.error =~ "adapter blew up"
    end
  end

  describe "deliver_many :stop" do
    test "records one email per item, matching results positionally" do
      tag = System.unique_integer([:positive])
      email_a = email(subject: "Batch A #{tag}")
      email_b = email(subject: "Batch B #{tag}")

      :telemetry.execute(
        [:swoosh, :deliver_many, :stop],
        %{duration: 1},
        %{
          emails: [email_a, email_b],
          mailer: MyTestApp.Mailer,
          config: [],
          result: [%{id: "batch-#{tag}-a"}, %{id: "batch-#{tag}-b"}]
        }
      )

      recorded_a = find_by_message_id("batch-#{tag}-a")
      recorded_b = find_by_message_id("batch-#{tag}-b")

      assert recorded_a.subject == "Batch A #{tag}"
      assert recorded_b.subject == "Batch B #{tag}"
    end
  end

  describe "capture toggles" do
    test "does not persist anything when disabled" do
      Application.put_env(:squatch_mail, :enabled, false)

      subject = "Disabled #{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:swoosh, :deliver, :stop],
        %{duration: 1},
        %{email: email(subject: subject), mailer: MyTestApp.Mailer, config: [], result: %{}}
      )

      # Give any (incorrect) async write a chance to land before asserting
      # its absence.
      Process.sleep(50)
      refute Tracker.list_emails(%{limit: 1000}) |> Enum.any?(&(&1.subject == subject))
    after
      Application.put_env(:squatch_mail, :enabled, true)
    end

    test "does not persist anything when sample_rate is 0.0" do
      Application.put_env(:squatch_mail, :sample_rate, 0.0)

      subject = "Sampled out #{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:swoosh, :deliver, :stop],
        %{duration: 1},
        %{email: email(subject: subject), mailer: MyTestApp.Mailer, config: [], result: %{}}
      )

      Process.sleep(50)
      refute Tracker.list_emails(%{limit: 1000}) |> Enum.any?(&(&1.subject == subject))
    after
      Application.delete_env(:squatch_mail, :sample_rate)
    end
  end
end
