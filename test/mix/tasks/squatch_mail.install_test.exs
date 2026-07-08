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

  ## ---- webhook raw-body reader (endpoint patching) ---------------------------

  describe "squatch_mail.install webhook raw-body reader" do
    test "patches a standard phx.new endpoint's Plug.Parsers with the generated reader" do
      igniter =
        phx_test_project()
        |> Igniter.compose_task("squatch_mail.install", [])

      igniter
      |> assert_creates("lib/test_web/squatch_mail_body_reader.ex")
      |> assert_has_patch("lib/test_web/endpoint.ex", """
      + |    body_reader: {TestWeb.SquatchMailBodyReader, :read_body, []}
      """)

      assert %{rewrite: rewrite} = igniter

      reader_source = Rewrite.source!(rewrite, "lib/test_web/squatch_mail_body_reader.ex")
      reader_content = Rewrite.Source.get(reader_source, :content)

      assert reader_content =~ "defmodule TestWeb.SquatchMailBodyReader"
      assert reader_content =~ ~s(@path_segments ["squatch"])
      assert reader_content =~ "SquatchMail.SNS.RawBodyReader.read_body(conn, opts)"
      assert reader_content =~ "Plug.Conn.read_body(conn, opts)"

      igniter
      |> assert_has_notice(&(&1 =~ "preserves the raw bytes SNS signatures need"))
    end

    test "respects --dashboard-path in the generated reader's path_segments" do
      igniter =
        phx_test_project()
        |> Igniter.compose_task("squatch_mail.install", ["--dashboard-path", "/mail/inbox"])

      assert %{rewrite: rewrite} = igniter
      reader_source = Rewrite.source!(rewrite, "lib/test_web/squatch_mail_body_reader.ex")
      reader_content = Rewrite.Source.get(reader_source, :content)

      assert reader_content =~ ~s(@path_segments ["mail", "inbox"])
    end

    test "already-wired is a no-op: re-running makes no further changes to the reader or endpoint" do
      installed =
        phx_test_project()
        |> Igniter.compose_task("squatch_mail.install", [])
        |> apply_igniter!()

      installed
      |> Igniter.compose_task("squatch_mail.install", [])
      |> assert_unchanged([
        "lib/test_web/endpoint.ex",
        "lib/test_web/squatch_mail_body_reader.ex"
      ])
      |> assert_has_notice(&(&1 =~ "already preserving raw SNS bytes"))
    end

    test "--no-dashboard still applies the endpoint patch: webhooks are independent of the dashboard mount" do
      igniter =
        phx_test_project()
        |> Igniter.compose_task("squatch_mail.install", ["--no-dashboard"])

      # The dashboard itself is NOT mounted...
      igniter |> assert_unchanged("lib/test_web/router.ex")

      # ...but the endpoint's raw-body wiring still happens, because the SNS
      # webhook route is independent of which dashboard pages are mounted.
      igniter
      |> assert_creates("lib/test_web/squatch_mail_body_reader.ex")
      |> assert_has_patch("lib/test_web/endpoint.ex", """
      + |    body_reader: {TestWeb.SquatchMailBodyReader, :read_body, []}
      """)
    end

    test "a non-standard Plug.Parsers call (dynamic opts) falls back to a loud notice instead of guessing" do
      # Start from a project whose endpoint already has a non-standard
      # Plug.Parsers call — options built from a module attribute rather
      # than a literal keyword list — applied and committed BEFORE the
      # installer runs, so `assert_unchanged/2` below compares against this
      # custom content, not the original phx.new template.
      custom_endpoint = """
      defmodule TestWeb.Endpoint do
        use Phoenix.Endpoint, otp_app: :test

        @session_options [
          store: :cookie,
          key: "_test_key",
          signing_salt: "dudFRY8V",
          same_site: "Lax"
        ]

        socket("/live", Phoenix.LiveView.Socket,
          websocket: [connect_info: [session: @session_options]],
          longpoll: [connect_info: [session: @session_options]]
        )

        plug(Plug.RequestId)
        plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

        @parser_opts [parsers: [:urlencoded, :multipart, :json], pass: ["*/*"]]
        plug(Plug.Parsers, @parser_opts)

        plug(Plug.MethodOverride)
        plug(Plug.Head)
        plug(Plug.Session, @session_options)
        plug(TestWeb.Router)
      end
      """

      project =
        phx_test_project()
        |> Igniter.update_elixir_file(
          "lib/test_web/endpoint.ex",
          &Igniter.Code.Common.replace_code(&1, custom_endpoint)
        )
        |> apply_igniter!()

      igniter = Igniter.compose_task(project, "squatch_mail.install", [])

      # No file is created and the endpoint is left untouched — we do not
      # guess at a shape we can't safely recognize.
      igniter
      |> assert_unchanged("lib/test_web/endpoint.ex")
      |> refute_creates("lib/test_web/squatch_mail_body_reader.ex")
      |> assert_has_notice(&(&1 =~ "could not automatically wire up the raw body reader"))
      |> assert_has_notice(&(&1 =~ "teach your endpoint to preserve the evidence yourself"))
      |> assert_has_notice(&(&1 =~ "could NOT wire up your endpoint's webhook raw-body"))
    end

    test "an endpoint whose Plug.Parsers already has a different, unrecognized body_reader is left untouched" do
      custom_endpoint = """
      defmodule TestWeb.Endpoint do
        use Phoenix.Endpoint, otp_app: :test

        @session_options [
          store: :cookie,
          key: "_test_key",
          signing_salt: "dudFRY8V",
          same_site: "Lax"
        ]

        socket("/live", Phoenix.LiveView.Socket,
          websocket: [connect_info: [session: @session_options]],
          longpoll: [connect_info: [session: @session_options]]
        )

        plug(Plug.RequestId)
        plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

        plug(Plug.Parsers,
          parsers: [:urlencoded, :multipart, :json],
          pass: ["*/*"],
          json_decoder: Phoenix.json_library(),
          body_reader: {TestWeb.SomeOtherCustomReader, :read_body, []}
        )

        plug(Plug.MethodOverride)
        plug(Plug.Head)
        plug(Plug.Session, @session_options)
        plug(TestWeb.Router)
      end
      """

      project =
        phx_test_project()
        |> Igniter.update_elixir_file(
          "lib/test_web/endpoint.ex",
          &Igniter.Code.Common.replace_code(&1, custom_endpoint)
        )
        |> apply_igniter!()

      project
      |> Igniter.compose_task("squatch_mail.install", [])
      |> assert_unchanged("lib/test_web/endpoint.ex")
      |> assert_has_notice(&(&1 =~ "a different `:body_reader` is already configured there"))
    end
  end
end
