defmodule SquatchMail.Web.ActivityExportTest do
  @moduledoc """
  Tests `GET <dashboard_path>/activity/export.csv` — the CSV download behind
  Trail Log's "Export CSV" button.
  """

  use SquatchMail.Web.WebCase, async: false

  alias SquatchMail.Tracker

  setup do
    Application.delete_env(:squatch_mail, :basic_auth)
    Application.put_env(:squatch_mail, :allow_unauthenticated, true)
    :ok
  end

  test "streams a CSV with a header row and one row per email", %{conn: conn} do
    {:ok, email} =
      Tracker.record_email(%{
        from_email: "camp@example.com",
        subject: "Export me",
        status: "delivered",
        recipients: [%{kind: "to", address: "hiker@example.com"}]
      })

    conn = get(conn, "/squatch/activity/export.csv")

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/csv"

    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert disposition =~ "trail-log.csv"

    lines = conn.resp_body |> String.trim() |> String.split("\n")

    assert ["public_id,status,from_email,subject,recipients,sent_at,inserted_at"] =
             Enum.take(lines, 1)

    assert Enum.any?(lines, &String.contains?(&1, email.public_id))
    assert Enum.any?(lines, &String.contains?(&1, "hiker@example.com"))
  end

  test "respects the status query param the same way the Trail Log filter does", %{conn: conn} do
    {:ok, delivered} =
      Tracker.record_email(%{
        from_email: "a@example.com",
        subject: "Delivered",
        status: "delivered",
        recipients: [%{kind: "to", address: "one@example.com"}]
      })

    {:ok, bounced} =
      Tracker.record_email(%{
        from_email: "a@example.com",
        subject: "Bounced",
        status: "bounced",
        recipients: [%{kind: "to", address: "two@example.com"}]
      })

    conn = get(conn, "/squatch/activity/export.csv?status=bounced")

    assert conn.resp_body =~ bounced.public_id
    refute conn.resp_body =~ delivered.public_id
  end

  test "quotes CSV fields containing commas", %{conn: conn} do
    {:ok, _email} =
      Tracker.record_email(%{
        from_email: "a@example.com",
        subject: "Hello, hiker",
        status: "sent",
        recipients: [%{kind: "to", address: "one@example.com"}]
      })

    conn = get(conn, "/squatch/activity/export.csv")

    assert conn.resp_body =~ ~s("Hello, hiker")
  end
end
