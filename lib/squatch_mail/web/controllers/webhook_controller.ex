defmodule SquatchMail.Web.WebhookController do
  @moduledoc """
  Receives inbound Amazon SNS/SES event notifications at
  `POST <dashboard_path>/webhooks/sns/:token`.

  This route intentionally lives outside the dashboard's `live_session` pipe
  (see `SquatchMail.Web.Router`): it is a machine-to-machine API endpoint
  authenticated by the per-source `:token` path segment, not a browser
  session, so it skips CSRF protection and session fetching entirely.

  ## Raw body requirement

  SNS signature verification needs the exact bytes SNS sent. The pipeline
  that mounts this route must configure `Plug.Parsers` with `body_reader:
  {SquatchMail.SNS.RawBodyReader, :read_body, []}` (scoped to this path is
  enough) so `conn.assigns[:raw_body]` is populated - see
  `SquatchMail.SNS.RawBodyReader`'s moduledoc for the exact plug pipeline
  snippet. If `:raw_body` isn't set (misconfigured pipeline), this falls back
  to re-encoding `conn.params` as JSON, which is **not** byte-identical to
  what SNS sent and will fail signature verification - that fallback exists
  only so the endpoint still responds predictably instead of crashing on a
  `nil` body.

  This is a plain `Plug`, not a `Phoenix.Controller` (same pattern as
  `SquatchMail.Web.AssetController`) - Phoenix's router dispatches `get`/
  `post` to either kind of module identically (`post "/path", Module,
  :create`), and a webhook endpoint doing a single JSON-in/status-code-out
  exchange doesn't need view/format negotiation.
  """

  @behaviour Plug

  import Plug.Conn

  alias SquatchMail.SNS.Processor

  @impl Plug
  def init(action), do: action

  @doc """
  Handles the inbound webhook POST. Always responds within the request
  cycle - SNS treats non-2xx as "retry", so the status code doubles as
  retry/no-retry signaling:

    * `200` - processed or intentionally ignored (no retry wanted).
    * `404` - unknown `:token` (retrying won't help; the token is wrong).
    * `403` - signature verification failed (retrying won't help either;
      it'll fail again unless the payload changes, which SNS won't do).
    * `500` - a transient failure (SubscribeURL confirmation GET failed,
      DB hiccup, etc) - retryable, so SNS retrying is the desired behavior.
  """
  @impl Plug
  def call(conn, :create) do
    token = conn.path_params["token"]
    raw_body = Map.get(conn.assigns, :raw_body) || Jason.encode!(conn.params)

    conn =
      case Processor.process(raw_body, token) do
        {:ok, _outcome} ->
          send_resp(conn, 200, "")

        {:error, :invalid_token} ->
          send_resp(conn, 404, "")

        {:error, {:signature_invalid, _reason}} ->
          send_resp(conn, 403, "")

        {:error, _reason} ->
          send_resp(conn, 500, "")
      end

    halt(conn)
  end
end
