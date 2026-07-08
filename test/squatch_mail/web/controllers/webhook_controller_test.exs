defmodule SquatchMail.Web.WebhookControllerTest do
  use SquatchMail.DataCase, async: false

  alias SquatchMail.Tracker
  alias SquatchMail.Web.WebhookController

  setup do
    Application.put_env(:squatch_mail, :verify_sns_signatures, false)
    on_exit(fn -> Application.delete_env(:squatch_mail, :verify_sns_signatures) end)

    source = Tracker.get_or_create_source()
    {:ok, source: source}
  end

  defp conn_for(token, body, raw_body \\ nil) do
    raw = raw_body || body

    Plug.Test.conn(:post, "/webhooks/sns/#{token}", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.fetch_query_params()
    |> Map.put(:params, Jason.decode!(body))
    |> Map.put(:path_params, %{"token" => token})
    |> Plug.Conn.assign(:raw_body, raw)
  end

  defp notification_body do
    Jason.encode!(%{
      "Type" => "Notification",
      "MessageId" => Ecto.UUID.generate(),
      "TopicArn" => "arn:aws:sns:us-east-1:123456789012:squatch-mail-ses-events",
      "Subject" => "Amazon SES Email Event Notification",
      "Message" => Jason.encode!(%{"eventType" => "Send", "mail" => %{"messageId" => "abc"}}),
      "Timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "SignatureVersion" => "1",
      "Signature" => "unused",
      "SigningCertURL" => "https://sns.us-east-1.amazonaws.com/cert.pem"
    })
  end

  test "init/1 passes the action through unchanged" do
    assert WebhookController.init(:create) == :create
  end

  test "responds 200 and processes a valid Notification", %{source: source} do
    conn = conn_for(source.webhook_token, notification_body())

    conn = WebhookController.call(conn, :create)

    assert conn.status == 200
    assert conn.halted
  end

  test "responds 404 for an unknown token" do
    conn = conn_for("not-a-real-token", notification_body())

    conn = WebhookController.call(conn, :create)

    assert conn.status == 404
  end

  test "responds 403 when signature verification fails" do
    Application.put_env(:squatch_mail, :verify_sns_signatures, true)

    source = Tracker.get_or_create_source()
    conn = conn_for(source.webhook_token, notification_body())

    conn = WebhookController.call(conn, :create)

    assert conn.status == 403
  end

  test "falls back to encoding conn.params when :raw_body is not assigned", %{source: source} do
    body = notification_body()

    conn =
      Plug.Test.conn(:post, "/webhooks/sns/#{source.webhook_token}", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.put(:params, Jason.decode!(body))
      |> Map.put(:path_params, %{"token" => source.webhook_token})

    conn = WebhookController.call(conn, :create)

    assert conn.status == 200
  end
end
