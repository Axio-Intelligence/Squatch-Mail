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

      igniter
      |> set_up_configuration(app_name, repo)
      |> set_up_formatter()
      |> set_up_database(repo)
      |> maybe_set_up_web_ui(mount_dashboard?, router, dashboard_path)
      |> Igniter.add_notice(next_steps_notice(mount_dashboard?, dashboard_path))
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
      def down, do: SquatchMail.Migrations.down(version: 1)
      """

      Igniter.Libs.Ecto.gen_migration(igniter, repo, "add_squatch_mail",
        body: migration_body,
        on_exists: :skip
      )
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

    defp next_steps_notice(mount_dashboard?, dashboard_path) do
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
      """
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
