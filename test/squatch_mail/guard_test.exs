defmodule SquatchMail.GuardTest do
  use SquatchMail.DataCase, async: false

  alias SquatchMail.{Email, Guard, Suppression, Tracker}

  defp sent_email(attrs) do
    {status, attrs} = Map.pop(attrs, :status, "sent")
    {sent_at, attrs} = Map.pop(attrs, :sent_at, DateTime.utc_now())

    {:ok, email} =
      Tracker.record_email(Map.merge(%{from_email: "sender@example.com"}, attrs))

    {:ok, email} =
      Tracker.mark_email_sent(email, "msg-#{System.unique_integer([:positive])}", sent_at)

    if status != "sent" do
      {:ok, email} = Tracker.update_email_status(email, status)
      email
    else
      email
    end
  end

  setup do
    # This module runs `async: false` (shared sandbox mode, required so the
    # Capture.Recorder's own process can see the connection) — which means
    # Ecto's usual per-test rollback does NOT happen. Every complaint-rate
    # test computes an aggregate over *all* rows in the emails table, so
    # without an explicit wipe between tests, an earlier test's fixture rows
    # (e.g. "999 sent + 1 complained") would silently pollute a later test's
    # ratio. Delete before each test instead of relying on transactional
    # isolation. Deliberately `DELETE FROM`, not `TRUNCATE`: other `async:
    # false` test modules (e.g. WatchtowerTest) run concurrently with this
    # one under ExUnit's scheduler, and TRUNCATE's AccessExclusiveLock
    # deadlocks against their concurrent reads — a real deadlock this
    # produced in practice. DELETE's row-level locking doesn't have that
    # problem, at the cost of not resetting the primary key sequence (which
    # nothing here depends on).
    SquatchMail.Test.Repo.delete_all(Email)
    SquatchMail.Test.Repo.delete_all(Suppression)

    # A raised complaint-rate threshold and no minimum volume by default so
    # a handful of test sends can trip the breaker without needing 100+
    # fixture rows per test; individual tests override where they need the
    # real defaults.
    Application.put_env(:squatch_mail, :guard,
      complaint_rate_pause: true,
      complaint_rate_threshold: 0.001,
      complaint_rate_window_days: 30,
      min_volume: 0
    )

    on_exit(fn -> Application.delete_env(:squatch_mail, :guard) end)
    :ok
  end

  describe "check/1" do
    test "returns :ok when nothing is suppressed and the complaint rate is fine" do
      assert :ok = Guard.check(["fresh@example.com"])
    end

    test "accepts a single address string" do
      assert :ok = Guard.check("fresh@example.com")
    end

    test "accepts a %Swoosh.Email{} and extracts to/cc/bcc" do
      {:ok, _} = Tracker.suppress(%{address: "bounced@example.com", reason: "hard_bounce"})

      email =
        Swoosh.Email.new(from: {"", "sender@example.com"}, to: "bounced@example.com")

      assert {:error, {:suppressed, ["bounced@example.com"]}} = Guard.check(email)
    end

    test "returns {:error, {:suppressed, addresses}} for suppressed recipients" do
      {:ok, _} = Tracker.suppress(%{address: "bounced@example.com", reason: "hard_bounce"})

      assert {:error, {:suppressed, ["bounced@example.com"]}} =
               Guard.check(["ok@example.com", "bounced@example.com"])
    end

    test "reports every suppressed address, not just the first" do
      {:ok, _} = Tracker.suppress(%{address: "a@example.com", reason: "complaint"})
      {:ok, _} = Tracker.suppress(%{address: "b@example.com", reason: "manual"})

      assert {:error, {:suppressed, suppressed}} =
               Guard.check(["a@example.com", "ok@example.com", "b@example.com"])

      assert Enum.sort(suppressed) == ["a@example.com", "b@example.com"]
    end

    test "an expired soft-bounce suppression no longer blocks" do
      {:ok, _} =
        Tracker.suppress(%{
          address: "expired@example.com",
          reason: "soft_bounce",
          expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })

      assert :ok = Guard.check(["expired@example.com"])
    end

    test "blocks all sends when the complaint rate is at/above threshold, regardless of recipient" do
      for _ <- 1..999, do: sent_email(%{})
      sent_email(%{status: "complained"})

      assert {:error, :complaint_rate_paused} = Guard.check(["anyone@example.com"])
    end

    test "does not count sends outside the trailing window" do
      old_sent_at = DateTime.add(DateTime.utc_now(), -31 * 86_400, :second)

      for _ <- 1..5, do: sent_email(%{sent_at: old_sent_at})
      sent_email(%{sent_at: old_sent_at, status: "complained"})

      assert Guard.complaint_rate() == 0.0
      assert :ok = Guard.check(["anyone@example.com"])
    end

    test "below :min_volume the breaker never trips even at 100% complaints" do
      Application.put_env(:squatch_mail, :guard,
        complaint_rate_pause: true,
        complaint_rate_threshold: 0.001,
        complaint_rate_window_days: 30,
        min_volume: 100
      )

      for _ <- 1..4, do: sent_email(%{status: "complained"})
      sent_email(%{})

      refute Guard.paused?()
      assert :ok = Guard.check(["anyone@example.com"])
    end

    test "complaint_rate_pause: false disables the breaker entirely" do
      Application.put_env(:squatch_mail, :guard,
        complaint_rate_pause: false,
        complaint_rate_threshold: 0.001,
        complaint_rate_window_days: 30,
        min_volume: 0
      )

      for _ <- 1..10, do: sent_email(%{})
      for _ <- 1..10, do: sent_email(%{status: "complained"})

      refute Guard.paused?()
      assert :ok = Guard.check(["anyone@example.com"])
    end
  end

  describe "complaint_rate/0 and paused?/0" do
    test "complaint_rate/0 returns 0.0 with no sends" do
      assert Guard.complaint_rate() == 0.0
    end

    test "paused?/0 is false below threshold, true at/above it" do
      for _ <- 1..999, do: sent_email(%{})
      refute Guard.paused?()

      # 1/1000 == 0.001, exactly at the default threshold.
      sent_email(%{status: "complained"})
      assert Guard.paused?()
    end

    test "respects a custom :complaint_rate_threshold" do
      Application.put_env(:squatch_mail, :guard,
        complaint_rate_pause: true,
        complaint_rate_threshold: 0.5,
        complaint_rate_window_days: 30,
        min_volume: 0
      )

      for _ <- 1..10, do: sent_email(%{})
      for _ <- 1..2, do: sent_email(%{status: "complained"})

      # 2/12 ~= 0.167, below the raised 0.5 threshold.
      refute Guard.paused?()
    end
  end

  describe "resend/2" do
    defmodule TestMailer do
      use Swoosh.Mailer, otp_app: :squatch_mail
    end

    setup do
      Application.put_env(:squatch_mail, TestMailer, adapter: Swoosh.Adapters.Test)

      # resend/2 does a genuine Mailer.deliver, which SquatchMail.Capture
      # (attached globally for the test run) would otherwise pick up and
      # persist asynchronously via a spawned Task — racing this test's
      # sandbox teardown for no benefit here, since these tests aren't
      # exercising capture.
      SquatchMail.Capture.detach()
      on_exit(&SquatchMail.Capture.attach/0)
      :ok
    end

    test "delivers through the given mailer when recipients pass the guard" do
      {:ok, email} =
        Tracker.record_email(%{
          from_email: "sender@example.com",
          from_name: "Sender",
          subject: "Resend me",
          html_body: "<p>hi</p>",
          recipients: [%{kind: "to", address: "recipient@example.com", name: "Rec"}]
        })

      assert {:ok, _result} = Guard.resend(email, TestMailer)
    end

    test "refuses to resend to a suppressed recipient" do
      {:ok, _} = Tracker.suppress(%{address: "blocked@example.com", reason: "manual"})

      {:ok, email} =
        Tracker.record_email(%{
          from_email: "sender@example.com",
          subject: "Resend me",
          recipients: [%{kind: "to", address: "blocked@example.com"}]
        })

      assert {:error, {:suppressed, ["blocked@example.com"]}} = Guard.resend(email, TestMailer)
    end
  end
end
