defmodule SquatchMail.SNS.RawBodyPlug do
  @moduledoc """
  Captures the exact raw request body into `conn.assigns[:raw_body]` for the
  SNS webhook route, independent of the host endpoint's `Plug.Parsers`.

  `SquatchMail.Web.Router` mounts this plug ahead of
  `SquatchMail.Web.WebhookController` for `POST .../webhooks/sns/:token` only.
  It exists because relying on `Plug.Parsers`'s `:body_reader` to capture the
  raw bytes is not sufficient for SNS:

  SNS delivers to HTTP/S endpoints with `Content-Type: text/plain;
  charset=UTF-8`. `Plug.Parsers` only invokes its `:body_reader` for a
  content-type one of its configured parsers *matches* — and the usual parser
  list (`[:urlencoded, :multipart, :json]`) matches none of `text/plain`. With
  `pass: ["*/*"]`, `Plug.Parsers` therefore returns the request with an **empty
  params map and the body still unread**, so a `:body_reader` never sees SNS's
  bytes and `conn.assigns[:raw_body]` is never set. `SquatchMail.SNS.Processor`
  then decodes the controller's `Jason.encode!(conn.params)` fallback — just the
  path params — finds no `"Type"` key, and every SNS message 500s.

  Because the host endpoint's `Plug.Parsers` runs *earlier* and leaves the
  `text/plain` body unread, this plug (running later, in SquatchMail's own
  router pipeline) can still read it. It reads the full body — following
  `{:more, ...}` chunking — and assigns it. `SquatchMail.SNS.MessageVerifier`
  needs those exact bytes to rebuild the signed string, and
  `SquatchMail.SNS.Processor.process/2` does its own JSON decode of them.

  If `conn.assigns[:raw_body]` is already a binary — e.g. a host wired
  `SquatchMail.SNS.RawBodyReader` into its endpoint's `Plug.Parsers`
  `:body_reader` (still supported) — this plug leaves it untouched. It is the
  reliable default; the body_reader is an optional belt-and-suspenders for hosts
  who prefer to capture at the endpoint.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Map.get(conn.assigns, :raw_body) do
      body when is_binary(body) -> conn
      _ -> read_raw_body(conn, "")
    end
  end

  defp read_raw_body(conn, acc) do
    case read_body(conn) do
      {:ok, chunk, conn} -> assign(conn, :raw_body, acc <> chunk)
      {:more, chunk, conn} -> read_raw_body(conn, acc <> chunk)
      {:error, _reason} -> conn
    end
  end
end
