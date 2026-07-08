defmodule SquatchMail.Web.Plugs.Auth do
  @moduledoc """
  Enforces layers (b) and (c) of `SquatchMail.Web.Router`'s security model.

  Layer (a) — a host `pipe_through`ing its own auth pipeline before mounting
  `squatch_mail_dashboard` — needs no code here at all; it's just the host's
  own plug running earlier in the same `scope`.

  This plug runs *before* `live_session`, in the plain Plug pipeline, which
  is the only place a real HTTP 401 (with a `www-authenticate` challenge) or
  a rendered refusal page can be sent — by the time a LiveView's `on_mount`
  hooks run, Phoenix has already committed to a 200 response for the dead
  render (see `Phoenix.LiveView.Router`'s own docs on this: auth belongs in
  a plug, `on_mount` is for post-auth assigns only).

  Precedence, checked in order:

    1. If `config :squatch_mail, :basic_auth` is set, enforce it via
       `Plug.BasicAuth` on every request (layer b).
    2. Otherwise, if a host `:on_mount` was supplied to `squatch_mail_dashboard`,
       assume the host is handling auth itself further up the pipeline and
       let the request through untouched (layer a).
    3. Otherwise — no basic_auth configured, no host on_mount given — allow
       the request through only when
       `Application.get_env(:squatch_mail, :allow_unauthenticated, false)` is
       true. When it is false, halt and render the refusal page (layer c).

  Asset routes (`.../assets/css-*`, `.../assets/js-*`) are mounted outside
  this plug's scope entirely (see `SquatchMail.Web.Router`), so they are
  never subject to any of the above.
  """

  import Plug.Conn

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    host_on_mount? = Keyword.get(opts, :host_on_mount?, false)

    case Application.get_env(:squatch_mail, :basic_auth) do
      [username: _, password: _] = basic_auth_opts ->
        Plug.BasicAuth.basic_auth(conn, basic_auth_opts)

      _ ->
        cond do
          host_on_mount? -> conn
          Application.get_env(:squatch_mail, :allow_unauthenticated, false) -> conn
          true -> refuse(conn)
        end
    end
  end

  defp refuse(conn) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(403, refusal_html())
    |> halt()
  end

  defp refusal_html do
    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <title>SquatchMail — access refused</title>
      </head>
      <body class="sq-root">
        <div class="sq-refusal">
          <div class="sq-refusal__card">
            <span class="sq-microlabel">// access refused</span>
            <h1 class="sq-refusal__title">This trail is off-limits.</h1>
            <p>
              SquatchMail refuses to mount its dashboard without some form of
              access control configured. This is the safe default for a
              production-like environment — nobody wants an email dashboard
              one <code>mix deps.get</code> away from being world-readable.
            </p>
            <p>Configure one of the following, then reload:</p>
            <p><strong>Recommended</strong> — mount inside your own authenticated pipeline:</p>
            <pre><code>scope "/" do
      pipe_through [:browser, :require_admin_user]
      squatch_mail_dashboard "/squatch", on_mount: [MyAppWeb.AdminAuth]
    end</code></pre>
            <p><strong>Fallback</strong> — HTTP Basic Auth:</p>
            <pre><code>config :squatch_mail,
      basic_auth: [username: "squatch", password: System.fetch_env!("SQUATCH_MAIL_PASSWORD")]</code></pre>
            <p>Running locally and want the dashboard open? Set:</p>
            <pre><code>config :squatch_mail, allow_unauthenticated: true</code></pre>
          </div>
        </div>
      </body>
    </html>
    """
  end
end
