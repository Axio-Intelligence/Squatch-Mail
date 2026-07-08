defmodule Mix.Tasks.SquatchMail.Install.Docs do
  @moduledoc false

  def short_doc do
    "Install and configure SquatchMail for use in this application."
  end

  def example do
    "mix squatch_mail.install"
  end

  def long_doc do
    """
    #{short_doc()}

    Adds SquatchMail's configuration to your `config.exs`, generates a
    migration that creates its tables (in their own `squatch_mail` Postgres
    schema), and mounts the dashboard in your Phoenix router.

    Safe to re-run: existing configuration, migrations, and router mounts are
    detected and left untouched.

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

    * `--dashboard-path` or `-d` - the path to mount the dashboard at.
      Defaults to `/squatch`.
    * `--no-dashboard` - skip mounting the dashboard router. Useful for
      telemetry-capture-only installs where the dashboard will be mounted
      by hand later (see the "Manual installation" section of the README).
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.SquatchMail.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    alias Igniter.Project.Config

    @default_dashboard_path "/squatch"

    # Common names hosts give a pipeline that gates access behind
    # authentication/authorization. If the router already has one of these,
    # we prefer mounting the dashboard behind it instead of the bare
    # `:browser` pipeline.
    @likely_auth_pipelines ~w(
      require_authenticated_user
      admin
      require_admin
      authenticated
      internal
    )a

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :squatch_mail,
        adds_deps: [],
        installs: [],
        example: __MODULE__.Docs.example(),
        only: nil,
        positional: [],
        composes: [],
        schema: [
          dashboard_path: :string,
          dashboard: :boolean
        ],
        defaults: [
          dashboard_path: @default_dashboard_path,
          dashboard: true
        ],
        aliases: [d: :dashboard_path],
        required: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)
      {igniter, repo} = Igniter.Libs.Ecto.select_repo(igniter)
      {igniter, router} = Igniter.Libs.Phoenix.select_router(igniter)

      dashboard_path = igniter.args.options[:dashboard_path] || @default_dashboard_path
      mount_dashboard? = Keyword.get(igniter.args.options, :dashboard, true)

      igniter =
        igniter
        |> set_up_configuration(app_name, repo)
        |> set_up_formatter()
        |> set_up_database(repo)
        |> maybe_set_up_web_ui(mount_dashboard?, router, dashboard_path)

      # The endpoint's raw-body wiring is independent of whether the
      # dashboard itself gets mounted (`--no-dashboard`): the SNS webhook
      # route is part of `squatch_mail_dashboard`'s own macro expansion, and
      # signature verification needs it regardless of which pages are
      # rendered. It's also independent of the router entirely — the fix
      # belongs on the *endpoint*, so it runs even when no router was found.
      {igniter, body_reader_status} = set_up_webhook_body_reader(igniter, router, dashboard_path)

      Igniter.add_notice(
        igniter,
        next_steps_notice(mount_dashboard?, dashboard_path, body_reader_status)
      )
    end

    defp set_up_configuration(igniter, app_name, repo) do
      igniter
      |> Config.configure_new("config.exs", :squatch_mail, [:repo], repo)
      |> Config.configure_new("config.exs", :squatch_mail, [:otp_app], app_name)
      |> Config.configure_new("config.exs", :squatch_mail, [:prefix], "squatch_mail")
      |> Config.configure_new("config.exs", :squatch_mail, [:enabled], true)
    end

    defp set_up_formatter(igniter) do
      Igniter.Project.Formatter.import_dep(igniter, :squatch_mail)
    end

    # `Igniter.Libs.Ecto.gen_migration/3` with `on_exists: :skip` already makes
    # this step idempotent: a second run finds the existing
    # `*_add_squatch_mail.exs` migration (matched by name, not timestamp) and
    # leaves it alone rather than generating a duplicate.
    defp set_up_database(igniter, repo) do
      migration_body = """
      def up, do: SquatchMail.Migrations.up()
      def down, do: SquatchMail.Migrations.down()
      """

      Igniter.Libs.Ecto.gen_migration(igniter, repo, "add_squatch_mail",
        body: migration_body,
        on_exists: :skip
      )
    end

    # `Plug.Parsers`'s `:body_reader` option is endpoint-wide (see
    # `SquatchMail.Web.Router`'s "Webhook raw body" moduledoc section) —
    # there is no way for the dashboard's router macro to arrange for SNS's
    # raw bytes to survive to `SquatchMail.SNS.RawBodyReader`. The installer
    # is the only place that can reach into the host's *endpoint*, so it
    # does the AST surgery here: generate a path-conditional body-reader
    # module and wire it into the endpoint's existing `Plug.Parsers` call.
    #
    # This is fragile territory on purpose: if the endpoint doesn't look
    # like a standard `mix phx.new` endpoint (no `Plug.Parsers` call, or one
    # we can't safely recognize as a plain keyword list, or one that already
    # has a *different* `:body_reader` wired up), we do not guess or
    # overwrite — we fall back to a loud notice with the exact copy-paste
    # snippet, the same way `set_up_web_ui/3` falls back to manual
    # instructions when no router is found.
    # Returns `{igniter, status}` where `status` is one of:
    #
    #   * `:wired` - the endpoint was patched (or created the reader module)
    #     just now.
    #   * `:already_wired` - a previous run already did this; true no-op.
    #   * `:needs_manual_action` - no endpoint was found, or the endpoint's
    #     `Plug.Parsers` shape was too fragile to patch safely; a loud notice
    #     with the copy-paste snippet was already added.
    #
    # `next_steps_notice/3` uses this to decide what to tell the user, since
    # a silent successful patch and a "go do this by hand" fallback need very
    # different closing instructions.
    defp set_up_webhook_body_reader(igniter, router, dashboard_path) do
      {igniter, endpoint} = Igniter.Libs.Phoenix.select_endpoint(igniter, router)

      case endpoint do
        nil ->
          {Igniter.add_notice(igniter, no_endpoint_found_notice(dashboard_path)),
           :needs_manual_action}

        endpoint ->
          patch_endpoint_body_reader(igniter, endpoint, dashboard_path)
      end
    end

    defp patch_endpoint_body_reader(igniter, endpoint, dashboard_path) do
      reader_module = Igniter.Libs.Phoenix.web_module_name(igniter, "SquatchMailBodyReader")
      path_segments = dashboard_path |> String.trim("/") |> String.split("/")

      case body_reader_status(igniter, endpoint, reader_module) do
        {:already_wired, igniter} ->
          {igniter, :already_wired}

        {:needs_wiring, igniter} ->
          igniter =
            igniter
            |> ensure_body_reader_module(reader_module, path_segments)
            |> wire_body_reader_into_parsers(endpoint, reader_module)

          {igniter, :wired}

        {:fragile, igniter} ->
          igniter =
            Igniter.add_notice(
              igniter,
              fragile_endpoint_notice(endpoint, reader_module, path_segments, dashboard_path)
            )

          {igniter, :needs_manual_action}
      end
    end

    # Inspects the endpoint's `plug(Plug.Parsers, opts)` call (if any) to
    # decide which of three states we're in:
    #
    #   * `:already_wired` - `body_reader:` is already set to *our* module.
    #     Re-running the installer must be a true no-op here.
    #   * `:needs_wiring` - a `Plug.Parsers` call exists, as a literal
    #     keyword list, with no `body_reader:` key (or an unset/nil one) —
    #     safe to patch.
    #   * `:fragile` - no `Plug.Parsers` call was found, its options aren't a
    #     plain literal keyword list we can safely inspect/modify, or
    #     `body_reader:` is already set to something that isn't ours (a host
    #     that has its own custom reader we must not clobber).
    defp body_reader_status(igniter, endpoint, reader_module) do
      {igniter, source, zipper} = Igniter.Project.Module.find_module!(igniter, endpoint)

      result =
        with {:ok, call_zipper} <- find_parsers_call(zipper),
             {:ok, opts_zipper} <- Igniter.Code.Function.move_to_nth_argument(call_zipper, 1),
             true <- Igniter.Code.List.list?(opts_zipper) do
          case Igniter.Code.Keyword.get_key(opts_zipper, :body_reader) do
            {:ok, value_zipper} ->
              if nodes_equal_to_reader?(value_zipper, reader_module) do
                :already_wired
              else
                :fragile
              end

            :error ->
              :needs_wiring
          end
        else
          _ -> :fragile
        end

      # find_module!/2 returns an igniter that must not be discarded even
      # when we only read from `source`/`zipper` here.
      _ = source
      {result, igniter}
    end

    defp find_parsers_call(zipper) do
      Igniter.Code.Function.move_to_function_call(
        zipper,
        :plug,
        [1, 2],
        &Igniter.Code.Function.argument_equals?(&1, 0, Plug.Parsers)
      )
    end

    defp nodes_equal_to_reader?(value_zipper, reader_module) do
      Igniter.Code.Common.nodes_equal?(value_zipper, reader_value_ast(reader_module))
    end

    defp ensure_body_reader_module(igniter, reader_module, path_segments) do
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, reader_module)

      if exists? do
        igniter
      else
        Igniter.Project.Module.create_module(igniter, reader_module, """
        @moduledoc \"\"\"
        Preserves the raw bytes of SquatchMail's inbound SNS webhook request so
        `SquatchMail.SNS.MessageVerifier` can check its signature against exactly
        what SNS sent — see `SquatchMail.Web.Router`'s moduledoc ("Webhook raw
        body") for why this can't be wired up anywhere but here, on the endpoint
        itself. Every other request (including the rest of the SquatchMail
        dashboard) falls through to the plain, uncached body reader.

        Generated by `mix squatch_mail.install`. Safe to edit if you move the
        dashboard to a different path later — update `path_segments/0` to match.
        \"\"\"

        @path_segments #{inspect(path_segments)}

        def read_body(conn, opts) do
          if match?(^@path_segments ++ ["webhooks", "sns", _token], conn.path_info) do
            SquatchMail.SNS.RawBodyReader.read_body(conn, opts)
          else
            Plug.Conn.read_body(conn, opts)
          end
        end
        """)
      end
    end

    defp wire_body_reader_into_parsers(igniter, endpoint, reader_module) do
      # `set_keyword_key/4`'s value argument is spliced into the source as
      # quoted code, not a runtime term — a bare `{reader_module, :read_body,
      # []}` tuple here is ambiguous with Elixir's 3-element-tuple AST
      # shorthand and corrupts Sourceror's line metadata on reformat (this
      # was caught by test/mix/tasks/squatch_mail.install_test.exs raising
      # `Access.get/3` deep inside Sourceror.LinesCorrector). Parse the
      # exact string we already use for equality-checking in
      # nodes_equal_to_reader?/2 instead, so both places construct the
      # identical AST shape.
      reader_ast = reader_value_ast(reader_module)

      Igniter.Project.Module.find_and_update_module!(igniter, endpoint, fn zipper ->
        with {:ok, call_zipper} <- find_parsers_call(zipper),
             {:ok, opts_zipper} <- Igniter.Code.Function.move_to_nth_argument(call_zipper, 1),
             {:ok, opts_zipper} <-
               Igniter.Code.Keyword.set_keyword_key(
                 opts_zipper,
                 :body_reader,
                 reader_ast
               ) do
          {:ok, opts_zipper}
        else
          _ -> {:ok, zipper}
        end
      end)
    end

    defp reader_value_ast(reader_module) do
      "{#{inspect(reader_module)}, :read_body, []}"
      |> Sourceror.parse_string!()
    end

    defp no_endpoint_found_notice(dashboard_path) do
      path_segments = dashboard_path |> String.trim("/") |> String.split("/")

      """
      No Phoenix endpoint was found, so SquatchMail could not wire up the raw \
      body reader the SNS webhook needs. Every real SNS notification will fail \
      signature verification until this is done by hand.

      #{manual_body_reader_snippet("MyAppWeb.SquatchMailBodyReader", path_segments)}
      """
    end

    defp fragile_endpoint_notice(endpoint, reader_module, path_segments, _dashboard_path) do
      """
      SquatchMail could not automatically wire up the raw body reader \
      #{inspect(endpoint)} needs for SNS webhook signature verification — its \
      `Plug.Parsers` options weren't in a shape the installer could safely \
      recognize (or a different `:body_reader` is already configured there). \
      Rather than guess and risk breaking your existing body parsing, teach \
      your endpoint to preserve the evidence yourself:

      #{manual_body_reader_snippet(inspect(reader_module), path_segments)}

      Every real SNS notification will fail signature verification until this \
      is wired up — see `SquatchMail.Web.Router`'s moduledoc ("Webhook raw \
      body") for why it can't be done automatically here.
      """
    end

    defp manual_body_reader_snippet(reader_module, path_segments) do
      """
          # in your endpoint.ex
          defmodule #{reader_module} do
            @path_segments #{inspect(path_segments)}

            def read_body(conn, opts) do
              if match?(^@path_segments ++ ["webhooks", "sns", _token], conn.path_info) do
                SquatchMail.SNS.RawBodyReader.read_body(conn, opts)
              else
                Plug.Conn.read_body(conn, opts)
              end
            end
          end

          plug Plug.Parsers,
            parsers: [:urlencoded, :multipart, :json],
            pass: ["*/*"],
            json_decoder: Phoenix.json_library(),
            body_reader: {#{reader_module}, :read_body, []}
      """
    end

    defp maybe_set_up_web_ui(igniter, false, _router, _dashboard_path), do: igniter

    defp maybe_set_up_web_ui(igniter, true, router, dashboard_path) do
      set_up_web_ui(igniter, router, dashboard_path)
    end

    defp set_up_web_ui(igniter, nil, _dashboard_path) do
      Igniter.add_warning(igniter, """
      No Phoenix router found or selected. SquatchMail's configuration and \
      migration were still set up, but the dashboard was not mounted.

      Please add the following to your router by hand once Phoenix is set up:

          import SquatchMail.Web.Router

          scope "/" do
            pipe_through :browser

            squatch_mail_dashboard #{inspect(@default_dashboard_path)}
          end

      Or run this installer again with:

          mix igniter.install squatch_mail
      """)
    end

    defp set_up_web_ui(igniter, router, dashboard_path) do
      if dashboard_already_mounted?(igniter, router) do
        igniter
      else
        {igniter, auth_pipeline} = find_auth_pipeline(igniter, router)
        do_mount_dashboard(igniter, router, dashboard_path, auth_pipeline)
      end
    end

    # Idempotency guard: if `squatch_mail_dashboard/1,2` is already called
    # anywhere in the router, don't add a second mount.
    defp dashboard_already_mounted?(igniter, router) do
      {_igniter, _source, zipper} = Igniter.Project.Module.find_module!(igniter, router)

      case Igniter.Code.Function.move_to_function_call(
             zipper,
             :squatch_mail_dashboard,
             [1, 2],
             fn _ -> true end
           ) do
        {:ok, _zipper} -> true
        _ -> false
      end
    end

    defp find_auth_pipeline(igniter, router) do
      Enum.reduce_while(@likely_auth_pipelines, {igniter, nil}, fn name, {igniter, nil} ->
        case Igniter.Libs.Phoenix.has_pipeline(igniter, router, name) do
          {igniter, true} -> {:halt, {igniter, name}}
          {igniter, false} -> {:cont, {igniter, nil}}
        end
      end)
    end

    defp do_mount_dashboard(igniter, router, dashboard_path, nil) do
      igniter
      |> import_web_router(router)
      |> Igniter.Libs.Phoenix.append_to_scope(
        "/",
        "squatch_mail_dashboard #{inspect(dashboard_path)}",
        router: router,
        with_pipelines: [:browser],
        placement: :after
      )
      |> Igniter.add_warning("""
      SquatchMail's dashboard was mounted behind the plain `:browser` pipeline \
      because no authenticated/admin pipeline (tried: \
      #{Enum.join(@likely_auth_pipelines, ", ")}) was found in your router.

      This means #{dashboard_path} has no access control. Before deploying,
      configure one of:

        * an `on_mount` authentication hook (see the `SquatchMail.Web.Router`
          moduledoc for the callback contract),
        * HTTP Basic Auth via the `:basic_auth` config option, or
        * `:allow_unauthenticated` if this is intentional (e.g. a
          network-isolated internal tool).
      """)
    end

    defp do_mount_dashboard(igniter, router, dashboard_path, auth_pipeline) do
      igniter
      |> import_web_router(router)
      |> Igniter.Libs.Phoenix.append_to_scope(
        "/",
        "squatch_mail_dashboard #{inspect(dashboard_path)}",
        router: router,
        with_pipelines: [auth_pipeline],
        placement: :after
      )
    end

    defp import_web_router(igniter, router) do
      Igniter.Project.Module.find_and_update_module!(igniter, router, fn zipper ->
        case Igniter.Code.Function.move_to_function_call(
               zipper,
               :import,
               1,
               &Igniter.Code.Function.argument_equals?(&1, 0, SquatchMail.Web.Router)
             ) do
          {:ok, _zipper} ->
            {:ok, zipper}

          _ ->
            {:ok,
             Igniter.Code.Common.add_code(zipper, "import SquatchMail.Web.Router",
               placement: :before
             )}
        end
      end)
    end

    defp next_steps_notice(mount_dashboard?, dashboard_path, body_reader_status) do
      dashboard_line =
        if mount_dashboard? do
          "  * Visit #{dashboard_path} after running migrations — the Squatch is watching your outbox now.\n"
        else
          ""
        end

      """
      SquatchMail is configured. Next steps:

        * Review the generated migration, then run:

            mix ecto.migrate

      #{dashboard_line}
        * SquatchMail observes mail sent through Swoosh automatically via \
      telemetry — no mailer changes required.
      #{webhook_body_reader_line(body_reader_status)}\
      """
    end

    defp webhook_body_reader_line(:wired) do
      "  * Your endpoint now preserves the raw bytes SNS signatures need — the " <>
        "trail evidence is intact. Nothing further to do for webhook setup.\n"
    end

    defp webhook_body_reader_line(:already_wired) do
      "  * Your endpoint was already preserving raw SNS bytes from a previous " <>
        "run — still intact, nothing further to do.\n"
    end

    defp webhook_body_reader_line(:needs_manual_action) do
      "  * SquatchMail could NOT wire up your endpoint's webhook raw-body " <>
        "reader automatically — see the notice above for the exact snippet. " <>
        "Every real SNS notification will fail signature verification until " <>
        "this is done.\n"
    end
  end
else
  defmodule Mix.Tasks.SquatchMail.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"

    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'squatch_mail.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
