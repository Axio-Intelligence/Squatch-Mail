defmodule SquatchMail.SNS.RawBodyReader do
  @moduledoc """
  A `Plug.Parsers` body reader that caches the raw request body in
  `conn.assigns[:raw_body]` before returning it for JSON parsing.

  `SquatchMail.SNS.MessageVerifier`/`SquatchMail.SNS.Processor.process/2` need
  the *exact* bytes SNS sent (to rebuild the signed string and, incidentally,
  because `Processor.process/2` does its own JSON decode) - by the time
  `Plug.Parsers` hands a controller a parsed `conn.params`, the original body
  is gone unless something captured it first.

  ## Do you need this?

  Usually **no**. `squatch_mail_dashboard` pipes the webhook route through
  `SquatchMail.SNS.RawBodyPlug`, which captures the raw body automatically —
  hosts don't have to wire anything. This module remains as an *optional*
  `Plug.Parsers` `:body_reader` for hosts that prefer to capture the raw body
  at the endpoint themselves; `RawBodyPlug` detects an already-set
  `conn.assigns[:raw_body]` and stands down, so the two never fight.

  Note that a `:body_reader` alone is **not** sufficient for SNS: SNS sends
  `Content-Type: text/plain; charset=UTF-8`, which `Plug.Parsers` matches no
  parser for, so it never invokes the `:body_reader` for a real SNS request.
  That is exactly why `RawBodyPlug` (which reads unconditionally, after the
  parsers pass the body through unread) is the reliable default.

  ## Wiring this in (optional)

  `Plug.Parsers` accepts a `:body_reader` option that must be a `{module,
  function, args}` tuple implementing the same contract as
  `Plug.Conn.read_body/2` (`{:ok, body, conn} | {:more, partial, conn} |
  {:error, term}`), invoked once per chunk. Point it at this module wherever
  the host endpoint configures `Plug.Parsers`:

      plug Plug.Parsers,
        parsers: [:json],
        json_decoder: Jason,
        body_reader: {SquatchMail.SNS.RawBodyReader, :read_body, []}

  This must run *before* `:json` parsing consumes the body.
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
