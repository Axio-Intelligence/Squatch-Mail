defmodule Mix.Tasks.SquatchMail.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

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
      assert migration_content =~ "SquatchMail.Migrations.down(version: 1)"

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
end
