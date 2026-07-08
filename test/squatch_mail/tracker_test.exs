defmodule SquatchMail.TrackerTest do
  use SquatchMail.DataCase, async: true

  alias SquatchMail.{Email, EmailEvent, Source, Suppression, Tracker}

  describe "record_email/1" do
    test "generates a unique public_id and inserts recipients + attachments" do
      {:ok, email} =
        Tracker.record_email(%{
          from_email: "sender@example.com",
          from_name: "Sender",
          subject: "Hello",
          recipients: [
            %{kind: "to", address: "a@example.com", name: "A"},
            %{kind: "cc", address: "b@example.com"}
          ],
          attachments: [
            %{filename: "report.pdf", content_type: "application/pdf", size: 1024}
          ]
        })

      assert String.starts_with?(email.public_id, "em_")
      assert email.status == "captured"
      assert email.has_attachments == true
      assert email.attachments_count == 1
      assert length(email.recipients) == 2
      assert length(email.attachments) == 1
    end

    test "public_ids are unique across records" do
      {:ok, e1} = Tracker.record_email(%{from_email: "a@example.com"})
      {:ok, e2} = Tracker.record_email(%{from_email: "a@example.com"})
      refute e1.public_id == e2.public_id
    end

    test "honors an explicitly-provided public_id" do
      {:ok, email} =
        Tracker.record_email(%{from_email: "a@example.com", public_id: "em_custom123"})

      assert email.public_id == "em_custom123"
    end

    test "no attachments => has_attachments false, count 0" do
      {:ok, email} = Tracker.record_email(%{from_email: "a@example.com"})
      assert email.has_attachments == false
      assert email.attachments_count == 0
    end

    test "links orphan events that arrived before the email (by message_id)" do
      # Event arrives first, no matching email yet.
      {:ok, event} =
        Tracker.record_event(%{
          event_type: "delivery",
          message_id: "msg-early-123",
          recipient: "a@example.com"
        })

      assert is_nil(event.email_id)

      # Now the email is recorded with the same message_id.
      {:ok, email} =
        Tracker.record_email(%{from_email: "a@example.com", message_id: "msg-early-123"})

      linked = Repo.get(EmailEvent, event.id)
      assert linked.email_id == email.id
    end
  end

  describe "update_email_status/2 and mark_email_sent/3" do
    test "update by struct" do
      {:ok, email} = Tracker.record_email(%{from_email: "a@example.com"})
      {:ok, updated} = Tracker.update_email_status(email, "failed")
      assert updated.status == "failed"
    end

    test "update by id" do
      {:ok, email} = Tracker.record_email(%{from_email: "a@example.com"})
      {:ok, updated} = Tracker.update_email_status(email.id, "delivered")
      assert updated.status == "delivered"
    end

    test "mark_email_sent sets message_id, sent_at, status" do
      {:ok, email} = Tracker.record_email(%{from_email: "a@example.com"})
      sent_at = ~U[2026-07-08 10:00:00.000000Z]
      {:ok, sent} = Tracker.mark_email_sent(email, "ses-msg-1", sent_at)

      assert sent.message_id == "ses-msg-1"
      assert sent.sent_at == sent_at
      assert sent.status == "sent"
    end
  end

  describe "next_status/2 (status rank / no regression)" do
    test "advances forward through engagement ranks" do
      assert Tracker.next_status("sent", "delivered") == "delivered"
      assert Tracker.next_status("delivered", "opened") == "opened"
      assert Tracker.next_status("opened", "clicked") == "clicked"
    end

    test "never regresses a higher-ranked status" do
      assert Tracker.next_status("clicked", "delivered") == "clicked"
      assert Tracker.next_status("opened", "delivered") == "opened"
    end

    test "terminal-negative statuses always win regardless of current rank" do
      assert Tracker.next_status("clicked", "bounced") == "bounced"
      assert Tracker.next_status("opened", "complained") == "complained"
      assert Tracker.next_status("delivered", "rejected") == "rejected"
    end

    test "a negative status is not overridden by a later positive one" do
      assert Tracker.next_status("bounced", "delivered") == "bounced"
      assert Tracker.next_status("complained", "opened") == "complained"
    end
  end

  describe "record_event/1 (linking + status advancement)" do
    test "event arriving after the email links immediately and advances status" do
      {:ok, email} =
        Tracker.record_email(%{from_email: "a@example.com", message_id: "msg-after-1"})

      {:ok, _} = Tracker.mark_email_sent(email, "msg-after-1")

      {:ok, event} =
        Tracker.record_event(%{event_type: "delivery", message_id: "msg-after-1"})

      assert event.email_id == email.id
      assert Repo.get(Email, email.id).status == "delivered"
    end

    test "later delivery does not regress a clicked email" do
      {:ok, email} =
        Tracker.record_email(%{from_email: "a@example.com", message_id: "msg-click-1"})

      {:ok, _} = Tracker.mark_email_sent(email, "msg-click-1")
      {:ok, _} = Tracker.record_event(%{event_type: "click", message_id: "msg-click-1"})
      assert Repo.get(Email, email.id).status == "clicked"

      # A late delivery event must not revert clicked -> delivered.
      {:ok, _} = Tracker.record_event(%{event_type: "delivery", message_id: "msg-click-1"})
      assert Repo.get(Email, email.id).status == "clicked"
    end

    test "bounce overrides an opened email" do
      {:ok, email} =
        Tracker.record_email(%{from_email: "a@example.com", message_id: "msg-bounce-1"})

      {:ok, _} = Tracker.record_event(%{event_type: "open", message_id: "msg-bounce-1"})
      assert Repo.get(Email, email.id).status == "opened"

      {:ok, _} = Tracker.record_event(%{event_type: "bounce", message_id: "msg-bounce-1"})
      assert Repo.get(Email, email.id).status == "bounced"
    end

    test "event with unknown message_id is stored unlinked" do
      {:ok, event} =
        Tracker.record_event(%{event_type: "delivery", message_id: "no-such-msg"})

      assert is_nil(event.email_id)
    end
  end

  describe "suppressions" do
    test "suppress inserts and suppressed? reports true" do
      {:ok, _} = Tracker.suppress(%{address: "bad@example.com", reason: "hard_bounce"})
      assert Tracker.suppressed?("bad@example.com")
    end

    test "suppress upserts on duplicate address" do
      {:ok, _} = Tracker.suppress(%{address: "dup@example.com", reason: "soft_bounce"})
      {:ok, s2} = Tracker.suppress(%{address: "dup@example.com", reason: "complaint"})

      assert s2.reason == "complaint"
      assert Repo.aggregate(Suppression, :count) == 1
    end

    test "suppressed? is false once expires_at has passed" do
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      {:ok, _} =
        Tracker.suppress(%{
          address: "expired@example.com",
          reason: "soft_bounce",
          expires_at: past
        })

      refute Tracker.suppressed?("expired@example.com")
    end

    test "suppressed? is true for a future expiry" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, _} =
        Tracker.suppress(%{
          address: "future@example.com",
          reason: "soft_bounce",
          expires_at: future
        })

      assert Tracker.suppressed?("future@example.com")
    end

    test "unsuppress deletes the row" do
      {:ok, _} = Tracker.suppress(%{address: "gone@example.com", reason: "manual"})
      assert {:ok, 1} = Tracker.unsuppress("gone@example.com")
      refute Tracker.suppressed?("gone@example.com")
    end

    test "list_suppressions filters by reason" do
      {:ok, _} = Tracker.suppress(%{address: "h@example.com", reason: "hard_bounce"})
      {:ok, _} = Tracker.suppress(%{address: "s@example.com", reason: "soft_bounce"})

      hard = Tracker.list_suppressions(%{reason: "hard_bounce"})
      assert length(hard) == 1
      assert hd(hard).address == "h@example.com"
    end
  end

  describe "list_emails/1" do
    setup do
      {:ok, e1} =
        Tracker.record_email(%{
          from_email: "alice@example.com",
          subject: "Invoice #42",
          recipients: [%{kind: "to", address: "bob@example.com"}]
        })

      {:ok, e1} = Tracker.update_email_status(e1, "delivered")

      {:ok, e2} =
        Tracker.record_email(%{
          from_email: "carol@example.com",
          subject: "Newsletter",
          recipients: [%{kind: "to", address: "dave@example.com"}]
        })

      {:ok, e2} = Tracker.update_email_status(e2, "bounced")

      %{e1: e1, e2: e2}
    end

    test "filters by status", %{e1: e1} do
      results = Tracker.list_emails(%{status: "delivered"})
      assert Enum.map(results, & &1.id) == [e1.id]
    end

    test "search matches subject", %{e1: e1} do
      results = Tracker.list_emails(%{search: "invoice"})
      assert Enum.map(results, & &1.id) == [e1.id]
    end

    test "search matches from_email", %{e2: e2} do
      results = Tracker.list_emails(%{search: "carol"})
      assert Enum.map(results, & &1.id) == [e2.id]
    end

    test "search matches recipient address", %{e1: e1} do
      results = Tracker.list_emails(%{search: "bob@"})
      assert Enum.map(results, & &1.id) == [e1.id]
    end

    test "preloads recipients" do
      [email | _] = Tracker.list_emails(%{limit: 1})
      assert %Ecto.Association.NotLoaded{} != email.recipients
      assert is_list(email.recipients)
    end

    test "respects limit and offset" do
      all = Tracker.list_emails(%{})
      assert length(all) == 2

      one = Tracker.list_emails(%{limit: 1})
      assert length(one) == 1

      offset = Tracker.list_emails(%{limit: 1, offset: 1})
      assert length(offset) == 1
      refute hd(one).id == hd(offset).id
    end

    test "filters by date range" do
      # Both fixtures are inserted "now"; a future-only range excludes them.
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert Tracker.list_emails(%{from_date: future}) == []

      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      assert length(Tracker.list_emails(%{from_date: past})) == 2
    end
  end

  describe "get_email!/1" do
    test "preloads recipients, attachments, and events ordered by occurred_at" do
      {:ok, email} =
        Tracker.record_email(%{
          from_email: "a@example.com",
          message_id: "msg-preload-1",
          recipients: [%{kind: "to", address: "r@example.com"}],
          attachments: [%{filename: "a.txt"}]
        })

      t1 = ~U[2026-07-08 09:00:00.000000Z]
      t2 = ~U[2026-07-08 10:00:00.000000Z]

      {:ok, _} =
        Tracker.record_event(%{
          event_type: "open",
          message_id: "msg-preload-1",
          occurred_at: t2
        })

      {:ok, _} =
        Tracker.record_event(%{
          event_type: "delivery",
          message_id: "msg-preload-1",
          occurred_at: t1
        })

      loaded = Tracker.get_email!(email.public_id)

      assert length(loaded.recipients) == 1
      assert length(loaded.attachments) == 1
      assert length(loaded.events) == 2
      assert Enum.map(loaded.events, & &1.occurred_at) == [t1, t2]
    end

    test "raises when not found" do
      assert_raise Ecto.NoResultsError, fn -> Tracker.get_email!("em_missing") end
    end
  end

  describe "stats/1" do
    setup do
      # Current window: [base, base + 1h). Prior window: [base - 1h, base).
      base = ~U[2026-07-08 12:00:00.000000Z]
      %{base: base}
    end

    defp insert_with_status_at(status, inserted_at) do
      {:ok, email} = Tracker.record_email(%{from_email: "a@example.com"})

      email
      |> Ecto.Changeset.change(status: status, inserted_at: inserted_at)
      |> Repo.update!()
    end

    test "counts, rates, and prior-period deltas", %{base: base} do
      cur = fn min -> DateTime.add(base, min * 60, :second) end
      prev = fn min -> DateTime.add(base, -3600 + min * 60, :second) end

      # Current period: 4 delivered, 1 opened, 1 clicked, 1 bounced.
      insert_with_status_at("delivered", cur.(1))
      insert_with_status_at("delivered", cur.(2))
      insert_with_status_at("delivered", cur.(3))
      insert_with_status_at("delivered", cur.(4))
      insert_with_status_at("opened", cur.(5))
      insert_with_status_at("clicked", cur.(6))
      insert_with_status_at("bounced", cur.(7))

      # Prior period: 2 delivered, 1 bounced.
      insert_with_status_at("delivered", prev.(1))
      insert_with_status_at("delivered", prev.(2))
      insert_with_status_at("bounced", prev.(3))

      stats = Tracker.stats(%{from: base, to: DateTime.add(base, 3600, :second)})

      # total in current window = 7
      assert stats.current.total == 7
      # delivered = delivered + opened + clicked = 4 + 1 + 1 = 6
      assert stats.current.delivered == 6
      # opened = opened + clicked = 2
      assert stats.current.opened == 2
      assert stats.current.clicked == 1
      assert stats.current.bounced == 1
      assert stats.current.complained == 0

      # previous window: total 3, delivered 2, bounced 1
      assert stats.previous.total == 3
      assert stats.previous.delivered == 2
      assert stats.previous.bounced == 1

      # rates: delivered/total = 6/7, opened/delivered = 2/6, clicked/delivered = 1/6
      assert stats.rates.delivered == Float.round(6 / 7 * 100, 2)
      assert stats.rates.opened == Float.round(2 / 6 * 100, 2)
      assert stats.rates.clicked == Float.round(1 / 6 * 100, 2)
      assert stats.rates.bounced == Float.round(1 / 7 * 100, 2)

      # deltas: total 7 vs 3 => (7-3)/3*100
      assert stats.deltas.total == Float.round((7 - 3) / 3 * 100, 2)
      # delivered 6 vs 2 => (6-2)/2*100 = 200.0
      assert stats.deltas.delivered == 200.0
      # complained 0 vs 0 => nil
      assert stats.deltas.complained == nil
    end
  end

  describe "prune/0" do
    test "deletes emails/events older than retention_days, keeps recent, cascades" do
      # Set retention to 30 days.
      {:ok, _} = Tracker.update_source(%{retention_days: 30})

      old_time = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
      recent_time = DateTime.add(DateTime.utc_now(), -5 * 86_400, :second)

      # Old email with recipient + attachment (should cascade delete).
      {:ok, old} =
        Tracker.record_email(%{
          from_email: "old@example.com",
          recipients: [%{kind: "to", address: "r@example.com"}],
          attachments: [%{filename: "old.txt"}]
        })

      old = old |> Ecto.Changeset.change(inserted_at: old_time) |> Repo.update!()

      # Recent email (should survive).
      {:ok, recent} = Tracker.record_email(%{from_email: "recent@example.com"})
      recent = recent |> Ecto.Changeset.change(inserted_at: recent_time) |> Repo.update!()

      # Orphan old event (no email_id) older than retention.
      {:ok, orphan} =
        Tracker.record_event(%{
          event_type: "delivery",
          message_id: "no-email",
          occurred_at: old_time
        })

      result = Tracker.prune()

      assert result.emails == 1
      assert result.events == 1

      refute Repo.get(Email, old.id)
      assert Repo.get(Email, recent.id)
      refute Repo.get(EmailEvent, orphan.id)

      # Cascade: recipients/attachments of the old email are gone.
      assert Repo.aggregate(SquatchMail.EmailRecipient, :count) == 0
      assert Repo.aggregate(SquatchMail.EmailAttachment, :count) == 0
    end

    test "defaults to 90 days when no source retention is unusable" do
      # get_or_create_source will create a default (retention 90).
      very_old = DateTime.add(DateTime.utc_now(), -100 * 86_400, :second)
      {:ok, old} = Tracker.record_email(%{from_email: "a@example.com"})
      old |> Ecto.Changeset.change(inserted_at: very_old) |> Repo.update!()

      result = Tracker.prune()
      assert result.emails == 1
    end
  end

  describe "source" do
    test "get_or_create_source creates a single row with a webhook_token" do
      source = Tracker.get_or_create_source()
      assert %Source{} = source
      assert is_binary(source.webhook_token)
      assert source.retention_days == 90

      # Second call returns the same row (no duplicate).
      again = Tracker.get_or_create_source()
      assert again.id == source.id
      assert Repo.aggregate(Source, :count) == 1
    end

    test "update_source updates fields" do
      {:ok, updated} = Tracker.update_source(%{region: "eu-west-1", retention_days: 45})
      assert updated.region == "eu-west-1"
      assert updated.retention_days == 45
    end
  end
end
