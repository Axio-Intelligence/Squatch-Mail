defmodule Mix.Tasks.SquatchMail.InstallTest do
  # async: false + env snapshot/restore: Igniter's test project machinery
  # evaluates the patched host config into this VM's application env, which
  # transiently rewrites :squatch_mail keys (e.g. `repo: Test.Repo`) that
  # concurrently-running tests read through SquatchMail.Config. Serializing
  # this module and restoring the env after each test keeps that mutation
  # from poisoning the rest of the suite.
  use ExUnit.Case, async: false

  import Igniter.Test

  setup do
    snapshot = Application.get_all_env(:squatch_mail)

    on_exit(fn ->
      current = Application.get_all_env(:squatch_mail)

      for {key, _} <- current, not Keyword.has_key?(snapshot, key) do
        Application.delete_env(:squatch_mail, key)
      end

      for {key, value} <- snapshot do
        Application.put_env(:squatch_mail, key, value)
      end
    end)

    :ok
  end

  describe "squatch_mail.install" do
    test "configures the app, generates a migration, and mounts the dashboard" do
      igniter =
        phx_test_project()
        |> Igniter.compose_task("squatch_mail.install", [])

      igniter
      |> assert_has_patch("config/config.exs", """
      + |config :squatch_mail, repo: Test.Repo, otp_app: :test, prefix: "squatch_mail", enabled: true
      """)

      assert %{rewrite: rewrite} = igniter

      migration_path =
        rewrite
        |> Rewrite.paths()
        |> Enum.find(&String.contains?(&1, "add_squatch_mail"))

      assert migration_path, "expected a generated migration for add_squatch_mail"

      migration_source = Rewrite.source!(rewrite, migration_path)
      migration_content = Rewrite.Source.get(migration_source, :content)

      assert migration_content =~ "SquatchMail.Migrations.up()"
      assert migration_content =~ "SquatchMail.Migrations.down()"

      igniter
      |> assert_has_patch("lib/test_web/router.ex", """
      + |  import SquatchMail.Web.Router
      """)

      igniter
      |> assert_has_patch("lib/test_web/router.ex", """
      + |    squatch_mail_dashboard("/squatch")
      """)
    end

    test "respects --dashboard-path" do
      igniter =
        phx_test_project()
        |> Igniter.compose_task("squatch_mail.install", ["--dashboard-path", "/mail"])

      igniter
      |> assert_has_patch("lib/test_web/router.ex", """
      + |  squatch_mail_dashboard("/mail")
      """)
    end

    test "skips mounting the dashboard with --no-dashboard" do
      igniter =
        phx_test_project()
        |> Igniter.compose_task("squatch_mail.install", ["--no-dashboard"])

      igniter |> assert_unchanged("lib/test_web/router.ex")
    end

    test "mounts behind an existing authenticated pipeline instead of :browser" do
      igniter =
        phx_test_project()
        |> Igniter.Libs.Phoenix.add_pipeline(:require_authenticated_user, """
        plug :require_authenticated_user
        """)
        |> apply_igniter!()
        |> Igniter.compose_task("squatch_mail.install", [])

      igniter
      |> assert_has_patch("lib/test_web/router.ex", """
      + |    squatch_mail_dashboard("/squatch")
      """)

      refute Enum.any?(igniter.warnings, &(&1 =~ "no authenticated/admin pipeline"))
    end

    test "warns about missing access control when mounting behind :browser" do
      igniter =
        phx_test_project()
        |> Igniter.compose_task("squatch_mail.install", [])

      assert Enum.any?(igniter.warnings, &(&1 =~ "no access control"))
    end

    test "running twice is idempotent: the second run makes no further changes" do
      installed =
        phx_test_project()
        |> Igniter.compose_task("squatch_mail.install", [])
        |> apply_igniter!()

      installed
      |> Igniter.compose_task("squatch_mail.install", [])
      |> assert_unchanged()
    end
  end

  ## ---- webhook raw-body capture (router-level plug, no endpoint patching) ----

  describe "squatch_mail.install webhook raw-body capture" do
    test "does not patch the host endpoint: raw-body capture is the router's RawBodyPlug" do
      # The SNS webhook route captures its own raw body via
      # SquatchMail.SNS.RawBodyPlug (mounted by the dashboard macro), so the
      # installer must NOT touch the host endpoint or generate a body_reader
      # module — the fragile endpoint AST surgery is gone entirely.
      igniter =
        phx_test_project()
        |> Igniter.compose_task("squatch_mail.install", [])

      igniter
      |> assert_unchanged("lib/test_web/endpoint.ex")
      |> refute_creates("lib/test_web/squatch_mail_body_reader.ex")

      # And the user is told setup is complete with nothing to wire by hand.
      igniter
      |> assert_has_notice(&(&1 =~ "captures its own raw request body"))
      |> assert_has_notice(&(&1 =~ "no endpoint changes required"))
    end

    test "--no-dashboard leaves both the router and the endpoint untouched" do
      igniter =
        phx_test_project()
        |> Igniter.compose_task("squatch_mail.install", ["--no-dashboard"])

      igniter
      |> assert_unchanged("lib/test_web/router.ex")
      |> assert_unchanged("lib/test_web/endpoint.ex")
      |> refute_creates("lib/test_web/squatch_mail_body_reader.ex")
    end
  end
end
