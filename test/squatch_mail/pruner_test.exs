defmodule SquatchMail.PrunerTest do
  use SquatchMail.DataCase, async: false

  alias SquatchMail.{Email, Pruner, Tracker, WebhookLog}
  alias SquatchMail.Test.Repo

  test "run_now/0 prunes emails/events/webhook_logs older than retention and emits telemetry" do
    {:ok, _} = Tracker.update_source(%{retention_days: 30})

    old_time = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
    recent_time = DateTime.add(DateTime.utc_now(), -5 * 86_400, :second)

    {:ok, old_email} = Tracker.record_email(%{from_email: "old@example.com"})
    old_email |> Ecto.Changeset.change(inserted_at: old_time) |> Repo.update!()

    {:ok, recent_email} = Tracker.record_email(%{from_email: "recent@example.com"})
    recent_email |> Ecto.Changeset.change(inserted_at: recent_time) |> Repo.update!()

    old_webhook_time = DateTime.add(DateTime.utc_now(), -31 * 86_400, :second)
    recent_webhook_time = DateTime.add(DateTime.utc_now(), -5 * 86_400, :second)

    {:ok, old_log} = Tracker.log_webhook(%{provider: "ses", status: "received"})
    old_log |> Ecto.Changeset.change(inserted_at: old_webhook_time) |> Repo.update!()

    {:ok, recent_log} = Tracker.log_webhook(%{provider: "ses", status: "received"})
    recent_log |> Ecto.Changeset.change(inserted_at: recent_webhook_time) |> Repo.update!()

    handler_id = "pruner-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:squatch_mail, :prune, :done],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    result = Pruner.run_now()

    assert result.emails == 1
    assert result.webhook_logs == 1

    refute Repo.get(Email, old_email.id)
    assert Repo.get(Email, recent_email.id)
    refute Repo.get(WebhookLog, old_log.id)
    assert Repo.get(WebhookLog, recent_log.id)

    assert_received {:telemetry, measurements, metadata}
    assert measurements.emails == result.emails
    assert measurements.webhook_logs == result.webhook_logs
    assert metadata.events == result.events
  end

  test "run_now/0 returns zeros and still emits telemetry when there is nothing to prune" do
    handler_id = "pruner-test-empty-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:squatch_mail, :prune, :done],
      fn _event, measurements, _metadata, _config ->
        send(test_pid, {:telemetry, measurements})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert %{emails: 0, events: 0, webhook_logs: 0} = Pruner.run_now()
    assert_received {:telemetry, %{emails: 0, webhook_logs: 0}}
  end
end
