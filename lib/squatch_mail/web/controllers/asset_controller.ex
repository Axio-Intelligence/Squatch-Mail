defmodule SquatchMail.Web.AssetController do
  @moduledoc """
  Serves SquatchMail's self-contained CSS/JS bundle with content-hashed,
  immutable-cached paths.

  This follows the same pattern as Phoenix LiveDashboard's and Oban Web's
  asset plugs: the built `priv/static/squatch_mail.{css,js}` files are read
  once at compile time into module attributes, an MD5 hash of each is
  computed as a compile-time constant, and that hash is embedded in the
  asset's URL (`/assets/css-<md5>`, `/assets/js-<md5>`). Because the path
  itself changes whenever the content changes, the response can be marked
  `cache-control: public, max-age=31536000, immutable` — the browser never
  needs to revalidate, and a fresh deploy naturally busts the cache by
  generating a new path.

  This is a plain `Plug`, not a `Phoenix.Controller` — serving two static
  blobs doesn't need view/format negotiation, and Phoenix routers dispatch to
  either kind of module identically (`get "/path", Module, :action`).

  The `:md5` route parameter is not read by this plug; it exists only so a
  new build produces a new URL. The real, current hash used to build links
  is `asset_path/1`, computed from the actual file contents.
  """

  @behaviour Plug

  import Plug.Conn

  @static_dir Application.app_dir(:squatch_mail, ["priv", "static"])

  css_path = Path.join(@static_dir, "squatch_mail.css")
  js_path = Path.join(@static_dir, "squatch_mail.js")

  @external_resource css_path
  @external_resource js_path

  @css File.read!(css_path)
  @js File.read!(js_path)

  @hashes %{
    css: Base.encode16(:crypto.hash(:md5, @css), case: :lower),
    js: Base.encode16(:crypto.hash(:md5, @js), case: :lower)
  }

  @doc """
  Returns the current asset path segment for `asset` (`:css` or `:js`),
  e.g. `"css-3f9c2a..."`. Used by `SquatchMail.Web.Layouts.root/1` to build
  the `<link>`/`<script>` src.
  """
  @spec asset_path(:css | :js) :: String.t()
  def asset_path(:css), do: "css-#{@hashes.css}"
  def asset_path(:js), do: "js-#{@hashes.js}"

  @impl Plug
  def init(action) when action in [:css, :js], do: action

  @impl Plug
  def call(conn, :css), do: serve(conn, @css, "text/css")
  def call(conn, :js), do: serve(conn, @js, "text/javascript")

  defp serve(conn, contents, content_type) do
    conn
    |> put_resp_header("content-type", content_type)
    |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
    |> put_private(:plug_skip_csrf_protection, true)
    |> send_resp(200, contents)
    |> halt()
  end
end
