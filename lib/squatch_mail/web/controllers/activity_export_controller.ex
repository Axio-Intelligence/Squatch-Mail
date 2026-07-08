defmodule SquatchMail.Web.ActivityExportController do
  @moduledoc """
  Streams the Trail Log's current filter set as a CSV download —
  `GET <dashboard_path>/activity/export.csv`.

  Accepts the same query params the Trail Log LiveView patches into its own
  URL (`status`, `q`, or `range` as one of `24h`/`7d`/`30d`/`all`), so
  "Export CSV" always downloads exactly what's on screen — see
  `SquatchMail.Web.Live.TrailLog.filters_from_params/1`, the single source
  of truth both this controller and the LiveView build `Tracker` filters
  from. Rows are streamed with `Plug.Conn.chunk/2` rather than built as one
  giant binary, so a large export doesn't hold the whole CSV in memory at
  once.

  This is a plain `Plug` (same pattern as `SquatchMail.Web.AssetController`
  and `SquatchMail.Web.WebhookController`) — a CSV download needs no
  view/format negotiation.
  """

  @behaviour Plug

  import Plug.Conn

  alias SquatchMail.Tracker
  alias SquatchMail.Web.Live.TrailLog

  @columns ~w(public_id status from_email subject recipients sent_at inserted_at)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    filters =
      conn.query_params
      |> TrailLog.filters_from_params()
      |> Map.take([:status, :search, :from_date, :to_date])
      |> Map.put(:limit, 10_000)

    conn =
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("content-disposition", ~s(attachment; filename="trail-log.csv"))
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, header_row())

    filters
    |> Tracker.list_emails()
    |> Enum.reduce_while(conn, fn email, conn ->
      case chunk(conn, csv_row(email)) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end

  defp header_row, do: Enum.map_join(@columns, ",", &csv_escape/1) <> "\n"

  defp csv_row(email) do
    [
      email.public_id,
      email.status,
      email.from_email,
      email.subject,
      recipients_column(email.recipients),
      to_string(email.sent_at),
      to_string(email.inserted_at)
    ]
    |> Enum.map_join(",", &csv_escape/1)
    |> Kernel.<>("\n")
  end

  defp recipients_column(recipients) do
    recipients
    |> Enum.map(& &1.address)
    |> Enum.join("; ")
  end

  defp csv_escape(nil), do: ""

  defp csv_escape(value) do
    string = to_string(value)

    if String.contains?(string, [",", "\"", "\n"]) do
      ~s("#{String.replace(string, "\"", "\"\"")}")
    else
      string
    end
  end
end
