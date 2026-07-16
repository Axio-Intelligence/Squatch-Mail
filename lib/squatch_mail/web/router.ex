defmodule SquatchMail.Web.Router do
  @moduledoc """
  Mounts the SquatchMail dashboard in a host Phoenix router.

      defmodule MyAppWeb.Router do
        use MyAppWeb, :router
        import SquatchMail.Web.Router

        scope "/" do
          pipe_through :browser
          squatch_mail_dashboard "/squatch"
        end
      end

  This expands to a `Phoenix.LiveView.Router.live_session/3` wrapping seven
  routes — Trail Log (`/`, the live activity feed), the Sightings archive
  (`/sightings`), the Sighting inspector (`/sightings/:public_id`), Bounces
  (`/bounces`), Complaints (`/complaints`), the Do-Not-Disturb registry
  (`/suppressions`), and Base Camp (`/base-camp`) — plus a
  `GET .../activity/export.csv` CSV
  download (same auth as the dashboard), `GET .../assets/*` routes for
  the dashboard's self-contained CSS/JS and logo (never auth-gated), and a
  `POST .../webhooks/sns/:token` route that forwards to
  `SquatchMail.Web.WebhookController` (authenticated by its token, not the
  dashboard's auth layers).

  ## Security

  SquatchMail ships **three layers** of access control, in order of
  precedence. Exactly one applies for any given request to a *dashboard*
  route (Trail Log, Sightings, Suppressions, Base Camp); the SNS webhook
  route is never covered by any of them — it authenticates itself via its
  per-source `:token` path segment instead (signature verification happens
  inside `SquatchMail.Web.WebhookController`).

  All three layers are enforced by `SquatchMail.Web.Plugs.Auth`, a plain
  `Plug` that runs *before* `live_session` in the ordinary Plug pipeline.
  This is deliberate: HTTP Basic Auth's `401` challenge and the refusal page
  in layer (c) both need to send a real HTTP status/headers before Phoenix
  commits to rendering a LiveView, which is only possible from a `Plug` — a
  LiveView `on_mount` hook only ever sees a `Phoenix.LiveView.Socket` and can
  at most redirect, never issue an arbitrary status code
  (see `Phoenix.LiveView.Router`'s own documentation on this exact
  limitation). `on_mount` remains the right place for post-auth concerns —
  SquatchMail uses `SquatchMail.Web.OnMount` there only to assign
  theme/config, never to gate access.

  ### a) Recommended: host-owned authentication

  Mount `squatch_mail_dashboard` inside your own authenticated/admin pipeline
  and pass your own `on_mount` hooks, exactly like Oban Web or
  Phoenix LiveDashboard:

      scope "/" do
        pipe_through [:browser, :require_admin_user]
        squatch_mail_dashboard "/squatch", on_mount: [MyAppWeb.AdminAuth]
      end

  Passing `:on_mount` tells `SquatchMail.Web.Plugs.Auth` that the host is
  handling authorization itself further up the pipeline (in
  `:require_admin_user` above), so layers (b) and (c) both stand down
  regardless of their configuration. This is the only layer that can express
  arbitrary authorization (roles, per-user scoping, SSO, etc.) — layers (b)
  and (c) exist as a safety net for hosts that mount the dashboard without
  wiring up their own auth, not as a replacement for it.

  ### b) Built-in fallback: HTTP Basic Auth

  If the host configures

      config :squatch_mail,
        basic_auth: [username: "squatch", password: System.fetch_env!("SQUATCH_MAIL_PASSWORD")]

  then every dashboard route (never the SNS webhook route) is protected by
  `Plug.BasicAuth` with those credentials — this check takes precedence over
  everything else, including a configured `:on_mount`, since configuring
  `:basic_auth` is an explicit, unambiguous request for that gate.

  ### c) Safe default: refuse in production

  If neither (a) nor (b) applies — no `:on_mount` was given to
  `squatch_mail_dashboard` *and* no `:basic_auth` is configured — SquatchMail
  checks `Application.get_env(:squatch_mail, :allow_unauthenticated, false)`.

    * In development, hosts are expected to be running locally, so leaving
      this unset is harmless and the dashboard mounts normally — set
      `config :squatch_mail, allow_unauthenticated: true` in `dev.exs` to
      make that explicit.
    * When unset (the default) and neither (a) nor (b) applies, dashboard
      routes instead render a refusal page explaining how to configure layer
      (a) or (b). This is a deliberately conservative default: an embeddable
      dashboard with no auth at all must never be one `mix deps.get` away
      from being reachable in production.

  This check is a runtime `Application.get_env/3` read, not `Mix.env()` —
  `Mix.env()` does not exist in a compiled release, so gating on it would
  silently disable the safety net in exactly the environment (production)
  where it matters most.

  Note that the refusal page's *own* CSS/JS still load: asset routes
  (`.../assets/css-*`, `.../assets/js-*`) are mounted outside the scope this
  plug covers, in any configuration, so the refusal page itself always
  renders correctly instead of appearing broken.

  ## Webhook raw body

  SNS signature verification (`SquatchMail.SNS.MessageVerifier`, used by
  `SquatchMail.Web.WebhookController`) needs the exact bytes SNS sent, not a
  round-tripped re-encoding of the parsed params. `squatch_mail_dashboard`
  handles this for you: the webhook route pipes through
  `SquatchMail.SNS.RawBodyPlug`, which reads the raw body into
  `conn.assigns[:raw_body]` before the controller runs. **Hosts need to wire
  up nothing** — not a `:body_reader`, not an endpoint change.

  This works even though the host endpoint's `Plug.Parsers` runs first,
  because SNS delivers with `Content-Type: text/plain; charset=UTF-8` and
  `Plug.Parsers` (with the usual `[:urlencoded, :multipart, :json]` parsers
  and `pass: ["*/*"]`) matches no parser for `text/plain` — so it passes the
  request through with the body **still unread**, leaving those bytes for
  `RawBodyPlug` to consume in SquatchMail's own pipeline. This is also why the
  earlier "endpoint-wide `:body_reader`, no router-level fix" framing was
  wrong for SNS: `Plug.Parsers` never invokes a `:body_reader` for
  `text/plain` at all, so an endpoint reader would never have fired for a real
  SNS request regardless.

  Hosts that already capture the raw body themselves still work: if
  `conn.assigns[:raw_body]` is already set (e.g. via
  `SquatchMail.SNS.RawBodyReader` wired into the endpoint's `Plug.Parsers`
  `:body_reader`), `RawBodyPlug` leaves it untouched. That path is an optional
  belt-and-suspenders, no longer a requirement. If, somehow, the raw body is
  not captured at all, `WebhookController` logs an actionable error and falls
  back to re-encoding `conn.params` — not byte-identical to what SNS sent, so
  signature verification will fail; see `SquatchMail.SNS.RawBodyPlug`'s
  moduledoc for the full detail.

  ## Options

    * `:on_mount` - a list of `on_mount` hooks run before SquatchMail's own.
      Also signals to layer (c) that the host is handling auth (see above).
    * `:as` - the `live_session` name. Defaults to `:squatch_mail_dashboard`.
      `live_session` names must be unique per router *module*, not per
      `scope` — if you mount `squatch_mail_dashboard` more than once in the
      same router (e.g. one internal, one customer-facing instance), give
      every mount after the first a distinct `:as`.
  """

  @doc """
  Mounts the SquatchMail dashboard at `path`. See the moduledoc for the full
  security model.
  """
  defmacro squatch_mail_dashboard(path, opts \\ []) do
    # The auth plug (layers b/c) must run in a genuine Plug pipeline, not an
    # `on_mount` hook — see the moduledoc for why. `Phoenix.Router.plug/2`
    # can only be called inside a named `pipeline` block, and `pipeline`
    # itself can only be declared at the router's top level, not nested
    # inside `scope` — so it's generated here, sitting just above the scope
    # it's piped through, with a name derived from the mount path so calling
    # `squatch_mail_dashboard` more than once in the same router (e.g. two
    # differently-authed mounts) doesn't collide.
    pipeline_name = :"squatch_mail_auth_#{:erlang.phash2(path)}"
    webhook_pipeline_name = :"squatch_mail_webhook_#{:erlang.phash2(path)}"

    quote bind_quoted: [
            path: path,
            opts: opts,
            pipeline_name: pipeline_name,
            webhook_pipeline_name: webhook_pipeline_name
          ] do
      {session_name, session_opts, auth_plug_opts} =
        SquatchMail.Web.Router.__options__(__MODULE__, path, opts)

      pipeline pipeline_name do
        plug SquatchMail.Web.Plugs.Auth, auth_plug_opts
      end

      # Captures the exact raw request bytes into `conn.assigns[:raw_body]`
      # for SNS signature verification — this is the piece the router *can*
      # own (unlike `Plug.Parsers`'s endpoint-wide `:body_reader`), because it
      # runs after the host endpoint's parsers have already passed SNS's
      # `text/plain` body through unread. See the "Webhook raw body" moduledoc
      # section and `SquatchMail.SNS.RawBodyPlug`.
      pipeline webhook_pipeline_name do
        plug SquatchMail.SNS.RawBodyPlug
      end

      # The SNS webhook lives in its own scope so it pipes through *only* the
      # raw-body pipeline (never the dashboard auth pipeline, and no dashboard
      # route pays for raw-body reading). It's a machine-to-machine API route
      # authenticated by its per-source `:token` segment, not a browser
      # session — it must skip CSRF protection (there is no session/cookie to
      # protect) and must never be gated by the dashboard's own auth layers.
      scope path, alias: false, as: false do
        import Phoenix.Router, only: [post: 4, pipe_through: 1]

        pipe_through webhook_pipeline_name

        post "/webhooks/sns/:token", SquatchMail.Web.WebhookController, :create,
          as: :squatch_mail_webhook,
          private: %{plug_skip_csrf_protection: true}
      end

      scope path, alias: false, as: false do
        import Phoenix.LiveView.Router, only: [live: 4, live_session: 3]
        import Phoenix.Router, only: [get: 4, pipe_through: 1]

        # Asset routes sit outside the auth pipeline and the live_session on
        # purpose: the dashboard's CSS/JS (including the refusal page's own
        # styling) must load no matter how — or whether — the routes below
        # are gated.
        get "/assets/css-:md5", SquatchMail.Web.AssetController, :css, as: :squatch_mail_asset

        get "/assets/js-:md5", SquatchMail.Web.AssetController, :js, as: :squatch_mail_asset

        get "/assets/logo-:md5", SquatchMail.Web.AssetController, :logo, as: :squatch_mail_asset

        pipe_through pipeline_name

        # CSV export is a plain controller download (not a LiveView), but it
        # carries the same data as the Trail Log table, so it's gated by the
        # same auth pipeline as the rest of the dashboard, unlike the asset
        # and webhook routes above.
        get "/activity/export.csv", SquatchMail.Web.ActivityExportController, :export,
          as: :squatch_mail_export

        live_session session_name, session_opts do
          live "/", SquatchMail.Web.Live.TrailLog, :index, as: session_name

          # The Sightings/Bounces/Complaints archive pages are the same
          # LiveView as the Trail Log with a per-`live_action` page config —
          # see `SquatchMail.Web.Live.TrailLog`'s moduledoc.
          live "/sightings", SquatchMail.Web.Live.TrailLog, :sightings, as: session_name
          live "/sightings/:public_id", SquatchMail.Web.Live.Sighting, :show, as: session_name
          live "/bounces", SquatchMail.Web.Live.TrailLog, :bounces, as: session_name
          live "/complaints", SquatchMail.Web.Live.TrailLog, :complaints, as: session_name

          live "/suppressions", SquatchMail.Web.Live.Suppressions, :index, as: session_name
          live "/base-camp", SquatchMail.Web.Live.BaseCamp, :index, as: session_name
        end
      end
    end
  end

  @doc false
  def __options__(router_module, path, opts) do
    scoped_path = Phoenix.Router.scoped_path(router_module, path)
    host_on_mount = Keyword.get(opts, :on_mount, [])
    session_name = Keyword.get(opts, :as, :squatch_mail_dashboard)

    # Host hooks run first (so they can halt/redirect before SquatchMail's
    # own hook assigns anything), then our default hook, which assigns
    # theme/config. Access control is fully handled by the plug installed
    # ahead of `live_session` (see the macro above) — `on_mount` here is
    # strictly post-auth.
    on_mount = host_on_mount ++ [{SquatchMail.Web.OnMount, :default}]

    session_opts = [
      session: {SquatchMail.Web.OnMount, :session, [scoped_path]},
      on_mount: on_mount,
      root_layout: {SquatchMail.Web.Layouts, :root}
    ]

    auth_plug_opts = [host_on_mount?: host_on_mount != []]

    {session_name, session_opts, auth_plug_opts}
  end
end
