defmodule SquatchMail.TelemetryCaptureTest do
  # Persistence happens on a Task spawned by SquatchMail.TelemetryCapture.Recorder,
  # off the process that fires the telemetry event or calls Mailer.deliver/2,
  # so the sandbox connection needs to be shared rather than owned
  # exclusively by this test's process.
  use SquatchMail.DataCase, async: false

  alias SquatchMail.{TelemetryCapture, Tracker}

  defmodule TestMailer do
    use Swoosh.Mailer, otp_app: :squatch_mail
  end

  setup do
    Application.put_env(:squatch_mail, TestMailer, adapter: Swoosh.Adapters.Test)

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

  # Persistence runs on a supervised Task via the Recorder's GenServer.cast,
  # so poll rather than assume a fixed sleep is enough (or too long) on a
  # loaded CI box.
  defp eventually(fun, attempts \\ 30) do
    case fun.() do
      nil when attempts > 0 ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      false when attempts > 0 ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      result ->
        result
    end
  end

  defp find_by_subject(subject) do
    eventually(fn ->
      Tracker.list_emails(%{limit: 1000})
      |> Enum.find(&(&1.subject == subject))
    end)
  end

  defp find_by_message_id(message_id) do
    eventually(fn ->
      Tracker.list_emails(%{limit: 1000})
      |> Enum.find(&(&1.message_id == message_id))
    end)
  end

  describe "real deliver/2 through Swoosh.Adapters.Test" do
    test "captures to/cc/bcc recipients and attachment metadata" do
      subject = "Real deliver #{System.unique_integer([:positive])}"

      email =
        [subject: subject]
        |> email()
        |> Swoosh.Email.cc({"CC Person", "cc@example.com"})
        |> Swoosh.Email.bcc("bcc@example.com")
        |> Swoosh.Email.attachment(Swoosh.Attachment.new({:data, "hi"}, filename: "note.txt"))

      {:ok, _result} = TestMailer.deliver(email)

      recorded = find_by_subject(subject)
      assert recorded
      # Swoosh.Adapters.Test returns {:ok, %{}} — no message_id available,
      # so a genuinely successful send with no id still lands as "captured"
      # rather than "sent" (see TelemetryCapture.status_for/2).
      assert recorded.status == "captured"
      assert recorded.from_email == "sender@example.com"
      assert recorded.from_name == "Sender"
      assert recorded.has_attachments == true
      assert recorded.attachments_count == 1

      full = Tracker.get_email!(recorded.public_id)

      assert Enum.any?(
               full.recipients,
               &(&1.address == "recipient@example.com" and &1.kind == "to")
             )

      assert Enum.any?(full.recipients, &(&1.address == "cc@example.com" and &1.kind == "cc"))
      assert Enum.any?(full.recipients, &(&1.address == "bcc@example.com" and &1.kind == "bcc"))
      assert Enum.any?(full.attachments, &(&1.filename == "note.txt"))
    end

    test "{name, email} tuples are unpacked into from_name/from_email and recipient name/address" do
      subject = "Tuple mailboxes #{System.unique_integer([:positive])}"
      email = email(subject: subject, to: {"Ada Lovelace", "ada@example.com"})

      {:ok, _result} = TestMailer.deliver(email)

      recorded = find_by_subject(subject)
      full = Tracker.get_email!(recorded.public_id)
      recipient = Enum.find(full.recipients, &(&1.kind == "to"))

      assert recipient.address == "ada@example.com"
      assert recipient.name == "Ada Lovelace"
    end
  end

  describe "message_id extraction (simulated adapter results)" do
    test "AmazonSES result shape (%{id: message_id}) marks the email sent" do
      message_id = "ses-#{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:swoosh, :deliver, :stop],
        %{duration: 1},
        %{
          email: email(),
          mailer: TestMailer,
          config: [adapter: Swoosh.Adapters.AmazonSES],
          result: %{id: message_id, request_id: "req-1"}
        }
      )

      recorded = find_by_message_id(message_id)
      assert recorded
      assert recorded.status == "sent"
    end

    test "raw SESv2 string-keyed result shape (%{\"MessageId\" => id}) marks the email sent" do
      message_id = "sesv2-#{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:swoosh, :deliver, :stop],
        %{duration: 1},
        %{email: email(), mailer: TestMailer, config: [], result: %{"MessageId" => message_id}}
      )

      recorded = find_by_message_id(message_id)
      assert recorded
      assert recorded.status == "sent"
    end
  end

  describe "failure capture" do
    test "an :error in :stop metadata records status failed with no message_id" do
      subject = "Adapter error #{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:swoosh, :deliver, :stop],
        %{duration: 1},
        %{email: email(subject: subject), mailer: TestMailer, config: [], error: :timeout}
      )

      recorded = find_by_subject(subject)
      assert recorded
      assert recorded.status == "failed"
      assert recorded.error =~ "timeout"
      assert recorded.message_id == nil
    end

    test ":exception event records status failed with the exception message" do
      subject = "Exception #{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:swoosh, :deliver, :exception],
        %{duration: 1},
        %{
          email: email(subject: subject),
          mailer: TestMailer,
          config: [],
          kind: :error,
          reason: %RuntimeError{message: "adapter blew up"},
          stacktrace: []
        }
      )

      recorded = find_by_subject(subject)
      assert recorded
      assert recorded.status == "failed"
      assert recorded.error =~ "adapter blew up"
    end
  end

  describe "deliver_many" do
    test "records one email per item, matching results positionally" do
      tag = System.unique_integer([:positive])
      email_a = email(subject: "Batch A #{tag}")
      email_b = email(subject: "Batch B #{tag}")

      :telemetry.execute(
        [:swoosh, :deliver_many, :stop],
        %{duration: 1},
        %{
          emails: [email_a, email_b],
          mailer: TestMailer,
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

  describe "config knobs" do
    test "disabled config no-ops entirely" do
      Application.put_env(:squatch_mail, :enabled, false)
      subject = "Disabled #{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:swoosh, :deliver, :stop],
        %{duration: 1},
        %{email: email(subject: subject), mailer: TestMailer, config: [], result: %{}}
      )

      # Give any (incorrect) write a chance to land before asserting absence.
      Process.sleep(50)
      refute Tracker.list_emails(%{limit: 1000}) |> Enum.any?(&(&1.subject == subject))
    after
      Application.put_env(:squatch_mail, :enabled, true)
    end

    test "sample_rate 0.0 captures nothing" do
      Application.put_env(:squatch_mail, :sample_rate, 0.0)
      subject = "Sampled out #{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:swoosh, :deliver, :stop],
        %{duration: 1},
        %{email: email(subject: subject), mailer: TestMailer, config: [], result: %{}}
      )

      Process.sleep(50)
      refute Tracker.list_emails(%{limit: 1000}) |> Enum.any?(&(&1.subject == subject))
    after
      Application.delete_env(:squatch_mail, :sample_rate)
    end

    test "store_html: false and store_text: false persist nil bodies but keep metadata" do
      Application.put_env(:squatch_mail, :store_html, false)
      Application.put_env(:squatch_mail, :store_text, false)
      subject = "No body storage #{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:swoosh, :deliver, :stop],
        %{duration: 1},
        %{email: email(subject: subject), mailer: TestMailer, config: [], result: %{}}
      )

      recorded = find_by_subject(subject)
      assert recorded
      assert recorded.html_body == nil
      assert recorded.text_body == nil
      assert recorded.from_email == "sender@example.com"
    after
      Application.delete_env(:squatch_mail, :store_html)
      Application.delete_env(:squatch_mail, :store_text)
    end
  end

  describe "queue overflow (Recorder backpressure)" do
    test "drops captures and emits [:squatch_mail, :capture, :dropped] when max_queue is exceeded" do
      Application.put_env(:squatch_mail, :max_queue, 0)

      test_pid = self()

      :telemetry.attach(
        "capture-overflow-test",
        [:squatch_mail, :capture, :dropped],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:dropped, measurements})
        end,
        nil
      )

      subject = "Overflow #{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:swoosh, :deliver, :stop],
        %{duration: 1},
        %{email: email(subject: subject), mailer: TestMailer, config: [], result: %{}}
      )

      assert_receive {:dropped, %{count: 1}}, 500

      # Give a (incorrect) write a chance to land before asserting it didn't.
      Process.sleep(50)
      refute Tracker.list_emails(%{limit: 1000}) |> Enum.any?(&(&1.subject == subject))
    after
      :telemetry.detach("capture-overflow-test")
      Application.delete_env(:squatch_mail, :max_queue)
    end

    test "never runs more than :max_concurrency persists at once" do
      Application.put_env(:squatch_mail, :max_concurrency, 1)
      Application.put_env(:squatch_mail, :max_queue, 10_000)

      tag = System.unique_integer([:positive])

      for n <- 1..5 do
        :telemetry.execute(
          [:swoosh, :deliver, :stop],
          %{duration: 1},
          %{
            email: email(subject: "Concurrency #{tag}-#{n}"),
            mailer: TestMailer,
            config: [],
            result: %{}
          }
        )
      end

      # Poll the Recorder's own state rather than sleep-and-hope: at every
      # observation, in-flight work must never exceed the configured cap,
      # even while 5 captures are still draining through it one at a time.
      max_observed_in_flight =
        Enum.reduce(1..50, 0, fn _, acc ->
          %{state: %{in_flight: in_flight}} =
            :sys.get_state(SquatchMail.TelemetryCapture.Recorder)

          Process.sleep(2)
          max(acc, map_size(in_flight))
        end)

      assert max_observed_in_flight <= 1

      eventually(fn ->
        count =
          Tracker.list_emails(%{limit: 1000})
          |> Enum.count(&String.starts_with?(&1.subject, "Concurrency #{tag}-"))

        if count == 5, do: count
      end)
    after
      Application.delete_env(:squatch_mail, :max_concurrency)
      Application.delete_env(:squatch_mail, :max_queue)
    end
  end
end
