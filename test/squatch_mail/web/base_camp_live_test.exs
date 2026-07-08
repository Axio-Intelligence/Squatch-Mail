defmodule SquatchMail.Web.BaseCampLiveTest do
  @moduledoc """
  End-to-end LiveView tests for Base Camp.

  In the test environment there are no AWS credentials, so every `SES.*` call
  returns `{:error, :missing_credentials}`. The important regression-safety
  case is that this degrades to the onboarding state rather than crashing
  `mount`/`handle_event`/`handle_async`.

  True happy-path provisioning coverage would require an injectable AWS client
  seam in `SquatchMail.SES` (its arity-1 functions build their own client from
  the source's credentials, with no override hook), which doesn't exist and
  lives in `ses.ex` — out of this file's territory. So provisioning is only
  exercised via its failure/degrade path here. Quota rendering is covered by
  seeding the `quota` map directly onto the source, bypassing SES entirely.
  """

  use SquatchMail.Web.WebCase, async: false

  alias SquatchMail.Tracker

  setup do
    Application.delete_env(:squatch_mail, :basic_auth)
    Application.put_env(:squatch_mail, :allow_unauthenticated, true)
    :ok
  end

  test "mounts the onboarding 'Connect your SES credentials' state without crashing", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, "/squatch/base-camp")

    assert html =~ "Base Camp"
    assert html =~ "Connect your SES credentials"
    assert html =~ "No camp pitched yet."
  end

  test "connection form always renders (works pre-connection)", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/squatch/base-camp")

    assert html =~ "Region"
    assert html =~ "Credentials mode"
    assert html =~ "us-east-1"
  end

  test "saving source settings updates the source", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/squatch/base-camp")

    html =
      view
      |> form("form[phx-submit='save_source']", %{
        "source" => %{"region" => "eu-west-1", "credentials_mode" => "ambient"}
      })
      |> render_submit()

    assert html =~ "Base Camp settings saved."
    assert html =~ "eu-west-1"
    assert Tracker.get_or_create_source().region == "eu-west-1"
  end

  test "switching to static mode reveals the credential inputs", %{conn: conn} do
    {:ok, _} = Tracker.update_source(%{credentials_mode: "static"})

    {:ok, _view, html} = live(conn, "/squatch/base-camp")

    assert html =~ "Access key ID"
    assert html =~ "Secret access key"
  end

  test "a stored secret is rendered masked, not in full", %{conn: conn} do
    {:ok, _} =
      Tracker.update_source(%{
        credentials_mode: "static",
        access_key_id: "AKIATEST",
        secret_access_key: "supersecret9999"
      })

    {:ok, _view, html} = live(conn, "/squatch/base-camp")

    refute html =~ "supersecret9999"
    assert html =~ "9999"
    assert html =~ "••••••••"
  end

  test "quota card renders seeded quota numbers", %{conn: conn} do
    {:ok, _} =
      Tracker.update_source(%{
        quota: %{
          "max_24_hour_send" => 50_000,
          "sent_last_24_hours" => 1200,
          "max_send_rate" => 14,
          "production_access_enabled" => true,
          "sending_enabled" => true
        },
        quota_checked_at: DateTime.utc_now()
      })

    {:ok, _view, html} = live(conn, "/squatch/base-camp")

    assert html =~ "50000"
    assert html =~ "1200"
    assert html =~ "production"
  end

  test "webhook endpoint card shows the path and 'The forest is listening.'", %{conn: conn} do
    source = Tracker.get_or_create_source()

    {:ok, _view, html} = live(conn, "/squatch/base-camp")

    assert html =~ "/webhooks/sns/" <> source.webhook_token
    assert html =~ "The forest is listening."
  end

  test "provisioning with no credentials degrades to the locked/onboarding state", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/squatch/base-camp")

    # start_async runs the provision call; with no AWS creds it returns
    # {:error, :missing_credentials}, which must not crash the view.
    html =
      view
      |> form("form[phx-submit='provision']", %{"webhook_base_url" => "https://myapp.example.com"})
      |> render_submit()

    # The view stays alive and eventually settles on the onboarding state.
    _ = render_async(view)
    assert render(view) =~ "Connect your SES credentials"
    assert html =~ "Base Camp"
  end

  test "identities section does not crash when not connected", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/squatch/base-camp")

    # render_async settles any in-flight start_async (list_identities) without
    # raising; the page remains the onboarding state.
    _ = render_async(view)
    assert render(view) =~ "Connect your SES credentials"
  end
end
