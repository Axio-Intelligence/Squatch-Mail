defmodule SquatchMail.Adapters.WatchtowerTest do
  use SquatchMail.DataCase, async: false

  alias SquatchMail.Adapters.Watchtower
  alias SquatchMail.Tracker

  # A minimal watched adapter that records every deliver/deliver_many call it
  # receives back to the test process, so tests can assert whether the
  # "real" adapter was ever reached.
  defmodule TestAdapter do
    # Not `use Swoosh.Adapter` — that macro generates its own always-matching
    # validate_config/1 (required_config: [] by default), which would shadow
    # the hand-written one below that needs to actually require a key.
    @behaviour Swoosh.Adapter

    @impl true
    def deliver(email, config) do
      send(config[:test_pid], {:delivered, email})
      {:ok, %{id: "test-message-id"}}
    end

    @impl true
    def deliver_many(emails, config) do
      send(config[:test_pid], {:delivered_many, emails})
      {:ok, Enum.map(emails, fn _ -> %{id: "test-message-id"} end)}
    end

    @impl true
    def validate_config(config) do
      Swoosh.Adapter.validate_config([:required_marker], config)
    end
  end

  defp email(to) do
    Swoosh.Email.new()
    |> Swoosh.Email.from("sender@example.com")
    |> Swoosh.Email.to(to)
  end

  defp config do
    [watched_adapter: TestAdapter, test_pid: self()]
  end

  describe "deliver/2" do
    test "delegates to the watched adapter when nothing is blocked" do
      assert {:ok, %{id: "test-message-id"}} =
               Watchtower.deliver(email("ok@example.com"), config())

      assert_received {:delivered, %Swoosh.Email{}}
    end

    test "blocks a suppressed recipient without ever reaching the watched adapter" do
      {:ok, _} = Tracker.suppress(%{address: "blocked@example.com", reason: "manual"})

      assert {:error, {:suppressed, ["blocked@example.com"]}} =
               Watchtower.deliver(email("blocked@example.com"), config())

      refute_received {:delivered, _}
    end

    test "blocks when the complaint-rate breaker is paused" do
      for _ <- 1..999 do
        {:ok, e} = Tracker.record_email(%{from_email: "sender@example.com"})
        {:ok, _} = Tracker.mark_email_sent(e, "msg-#{System.unique_integer([:positive])}")
      end

      {:ok, complained} = Tracker.record_email(%{from_email: "sender@example.com"})
      {:ok, complained} = Tracker.mark_email_sent(complained, "msg-complained")
      {:ok, _} = Tracker.update_email_status(complained, "complained")

      assert {:error, :complaint_rate_paused} =
               Watchtower.deliver(email("anyone@example.com"), config())

      refute_received {:delivered, _}
    end
  end

  describe "deliver_many/2 (all-or-nothing)" do
    test "delegates the whole batch when nothing is blocked" do
      emails = [email("a@example.com"), email("b@example.com")]

      assert {:ok, results} = Watchtower.deliver_many(emails, config())
      assert length(results) == 2
      assert_received {:delivered_many, ^emails}
    end

    test "any suppressed recipient anywhere in the batch blocks the entire batch" do
      {:ok, _} = Tracker.suppress(%{address: "blocked@example.com", reason: "manual"})

      emails = [email("clean@example.com"), email("blocked@example.com")]

      assert {:error, {:suppressed, ["blocked@example.com"]}} =
               Watchtower.deliver_many(emails, config())

      # Not even the clean email in the batch is sent - no partial delivery.
      refute_received {:delivered_many, _}
      refute_received {:delivered, _}
    end
  end

  describe "validate_config/1" do
    test "requires :watched_adapter" do
      assert_raise KeyError, fn -> Watchtower.validate_config(test_pid: self()) end
    end

    test "delegates to the watched adapter's validate_config/1 with :watched_adapter stripped" do
      assert_raise ArgumentError, fn ->
        Watchtower.validate_config(watched_adapter: TestAdapter, test_pid: self())
      end

      assert :ok =
               Watchtower.validate_config(
                 watched_adapter: TestAdapter,
                 required_marker: "present",
                 test_pid: self()
               )
    end

    test "treats a watched adapter with no validate_config/1 as passing" do
      defmodule NoValidateAdapter do
        @behaviour Swoosh.Adapter

        @impl true
        def deliver(_email, _config), do: {:ok, %{}}
      end

      assert :ok = Watchtower.validate_config(watched_adapter: NoValidateAdapter)
    end
  end
end
