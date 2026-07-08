defmodule SquatchMail.Web.OnMount do
  @moduledoc """
  The default `on_mount` hook and `live_session` session builder for the
  SquatchMail dashboard.

  Access control is fully handled ahead of `live_session` by
  `SquatchMail.Web.Plugs.Auth` (see `SquatchMail.Web.Router` for why it can't
  live here); this module is strictly post-auth. It assigns the dashboard's
  base path so layout components (nav links, asset URLs) can build paths
  relative to wherever the host mounted `squatch_mail_dashboard`. It is
  always appended last to the `on_mount` list so host hooks configured via
  `squatch_mail_dashboard(path, on_mount: [...])` run first.
  """

  import Phoenix.Component, only: [assign: 3]

  @doc false
  def session(_conn, dashboard_path) do
    %{"dashboard_path" => dashboard_path}
  end

  @doc false
  def on_mount(:default, _params, session, socket) do
    {:cont, assign(socket, :dashboard_path, Map.fetch!(session, "dashboard_path"))}
  end
end
