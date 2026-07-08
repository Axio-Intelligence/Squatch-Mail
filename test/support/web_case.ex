defmodule SquatchMail.Web.WebCase do
  @moduledoc """
  Test case for `SquatchMail.Web.Router` / dashboard tests. Boots
  `SquatchMail.Test.WebEndpoint` (a router with the dashboard mounted, no
  database) and wires up `Phoenix.ConnTest` + `Phoenix.LiveViewTest`.

  Every test that touches `Application.get_env(:squatch_mail, :basic_auth)`
  or `:allow_unauthenticated` restores those keys on exit, since they're
  process-independent global application env — tests that set them must not
  leak into other tests. Tagged `async: false` for this reason.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import SquatchMail.Web.WebCase

      alias SquatchMail.Test.WebEndpoint

      @endpoint WebEndpoint
    end
  end

  setup_all do
    ensure_test_web_stack_started()
    :ok
  end

  # The pubsub server and the endpoint are named, singleton processes shared
  # across every test *module* that uses this case — but each test module
  # runs its `setup_all` in its own short-lived process, and a plain
  # `Supervisor.start_link/2` links the supervisor to whichever process
  # calls it, so the whole tree would die the moment that first module's
  # tests finished. Starting it from a detached process (unlinked, and
  # outliving any single test module) keeps it alive for the rest of the
  # suite; a race against another test module doing the same is treated as
  # success via the `:already_started` match.
  defp ensure_test_web_stack_started do
    case Process.whereis(SquatchMail.Test.Supervisor) do
      nil -> start_detached()
      _pid -> :ok
    end
  end

  defp start_detached do
    owner = self()

    spawn(fn ->
      children = [
        {Phoenix.PubSub, name: SquatchMail.Test.PubSub},
        SquatchMail.Test.WebEndpoint
      ]

      result =
        Supervisor.start_link(children,
          strategy: :one_for_one,
          name: SquatchMail.Test.Supervisor
        )

      send(owner, {:web_stack_started, result})
      # Stay alive for the life of the test run so the supervisor (linked to
      # this process) isn't torn down when the calling test module finishes.
      Process.sleep(:infinity)
    end)

    receive do
      {:web_stack_started, {:ok, _pid}} -> :ok
      {:web_stack_started, {:error, {:already_started, _pid}}} -> :ok
    after
      5_000 -> raise "timed out starting SquatchMail.Test.Supervisor"
    end
  end

  setup do
    basic_auth_was = Application.get_env(:squatch_mail, :basic_auth)
    allow_unauthenticated_was = Application.get_env(:squatch_mail, :allow_unauthenticated)

    on_exit(fn ->
      put_or_delete(:basic_auth, basic_auth_was)
      put_or_delete(:allow_unauthenticated, allow_unauthenticated_was)
    end)

    # This case has no database of its own (see moduledoc) — but some
    # dashboard routes we route to (e.g. the SNS webhook controller) are
    # owned by another agent's data layer and do hit
    # `SquatchMail.Test.Repo`. Check out a sandbox connection for every test
    # here so those requests (dispatched in-process by `Phoenix.ConnTest`)
    # don't crash with a DBConnection.OwnershipError; this mirrors what
    # `SquatchMail.DataCase.setup_sandbox/1` does, without importing that
    # module (kept out of this case's territory otherwise).
    Ecto.Adapters.SQL.Sandbox.checkout(SquatchMail.Test.Repo)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:squatch_mail, key)
  defp put_or_delete(key, value), do: Application.put_env(:squatch_mail, key, value)
end
