defmodule SquatchMail.SNS.RawBodyReader do
  @moduledoc """
  A `Plug.Parsers` body reader that caches the raw request body in
  `conn.assigns[:raw_body]` before returning it for JSON parsing.

  `SquatchMail.SNS.MessageVerifier`/`SquatchMail.SNS.Processor.process/2` need
  the *exact* bytes SNS sent (to rebuild the signed string and, incidentally,
  because `Processor.process/2` does its own JSON decode) - by the time
  `Plug.Parsers` hands a controller a parsed `conn.params`, the original body
  is gone unless something captured it first.

  ## Wiring this in

  `Plug.Parsers` accepts a `:body_reader` option that must be a `{module,
  function, args}` tuple implementing the same contract as
  `Plug.Conn.read_body/2` (`{:ok, body, conn} | {:more, partial, conn} |
  {:error, term}`), invoked once per chunk. Point it at this module wherever
  the webhook route's pipeline configures `Plug.Parsers`, scoped to just the
  `/webhooks/sns/:token` path (raw-body caching in `conn.assigns` is a small,
  bounded cost - fine to scope broadly too, but the SNS route is the only one
  that needs it):

      plug Plug.Parsers,
        parsers: [:json],
        json_decoder: Jason,
        body_reader: {SquatchMail.SNS.RawBodyReader, :read_body, []}

  This must run *before* `:json` parsing consumes the body. The router or
  endpoint that mounts `SquatchMail.Web.WebhookController` needs a pipeline
  built this way for the webhook path (the dashboard's browser
  pipeline/live_session for the rest of the routes does not need this).
  """

  @doc """
  Drop-in replacement for `Plug.Conn.read_body/2` that additionally appends
  every chunk read to `conn.assigns[:raw_body]` (starting from `""`), so the
  full raw body is available under that key once parsing completes -
  including when the body arrives in multiple chunks (`{:more, ...}`).
  """
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()}
          | {:more, binary(), Plug.Conn.t()}
          | {:error, term()}
  def read_body(conn, opts \\ []) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} ->
        {:ok, chunk, append_raw_body(conn, chunk)}

      {:more, chunk, conn} ->
        {:more, chunk, append_raw_body(conn, chunk)}

      {:error, _reason} = error ->
        error
    end
  end

  defp append_raw_body(conn, chunk) do
    existing = Map.get(conn.assigns, :raw_body, "")
    Plug.Conn.assign(conn, :raw_body, existing <> chunk)
  end
end
