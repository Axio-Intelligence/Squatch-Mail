defmodule SquatchMail.SESTest do
  use SquatchMail.DataCase, async: true

  alias SquatchMail.{SES, Source, Tracker}
  alias SquatchMail.Test.AWSStub

  # A URL fragment that matches every AWS endpoint host used here.
  @sns_path "amazonaws.com/"
  @account_path "/v2/email/account"
  @config_sets_path "/v2/email/configuration-sets"
  @identities_path "/v2/email/identities"

  setup do
    stub = AWSStub.new()

    client =
      "AKIAEXAMPLE"
      |> AWS.Client.create("secret", "us-east-1")
      |> AWS.Client.put_http_client({AWSStub, agent: stub})

    %{stub: stub, client: client}
  end

  ## ---- client/1 -------------------------------------------------------------

  describe "client/1" do
    test "builds a static-credential client wired to the Finch pool" do
      source = %Source{
        credentials_mode: "static",
        region: "eu-west-1",
        access_key_id: "AKIASTATIC",
        secret_access_key: "shhh"
      }

      client = SES.client(source)

      assert client.access_key_id == "AKIASTATIC"
      assert client.secret_access_key == "shhh"
      assert client.region == "eu-west-1"
      assert client.http_client == {AWS.HTTPClient.Finch, finch_name: SquatchMail.Finch}
    end

    test "raises for static mode with missing keys" do
      source = %Source{credentials_mode: "static", region: "us-east-1"}

      assert_raise RuntimeError, ~r/missing an access_key_id/, fn ->
        SES.client(source)
      end
    end

    test "builds an ambient client from env vars" do
      source = %Source{credentials_mode: "ambient", region: "us-west-2"}

      with_env(
        %{
          "AWS_ACCESS_KEY_ID" => "AKIAENV",
          "AWS_SECRET_ACCESS_KEY" => "envsecret",
          "AWS_SESSION_TOKEN" => "token123"
        },
        fn ->
          client = SES.client(source)
          assert client.access_key_id == "AKIAENV"
          assert client.secret_access_key == "envsecret"
          assert client.session_token == "token123"
          assert client.region == "us-west-2"
          assert client.http_client == {AWS.HTTPClient.Finch, finch_name: SquatchMail.Finch}
        end
      )
    end

    test "raises for ambient mode with no env credentials" do
      source = %Source{credentials_mode: "ambient", region: "us-east-1"}

      with_env(%{"AWS_ACCESS_KEY_ID" => nil, "AWS_SECRET_ACCESS_KEY" => nil}, fn ->
        assert_raise RuntimeError, ~r/ambient.*credentials mode/s, fn ->
          SES.client(source)
        end
      end)
    end
  end

  ## ---- provision/3 ----------------------------------------------------------

  describe "provision/3 happy path" do
    test "creates config set, topic, subscription, event destination and persists",
         %{stub: stub, client: client} do
      source = Tracker.get_or_create_source()
      topic_arn = "arn:aws:sns:us-east-1:123456789012:squatch_mail-events"

      stub_create_configuration_set(stub)
      stub_create_topic(stub, topic_arn)
      stub_subscribe(stub, "#{topic_arn}:sub-1")

      webhook_url = "https://mail.example.com/webhooks/ses/tok123"

      assert {:ok, updated} = SES.provision(source, webhook_url, client)
      assert updated.configuration_set == "squatch_mail-events"
      assert updated.sns_topic_arn == topic_arn

      # Persisted to the DB.
      reloaded = Tracker.get_or_create_source()
      assert reloaded.sns_topic_arn == topic_arn
      assert reloaded.configuration_set == "squatch_mail-events"

      # The subscription carried our webhook URL over HTTPS.
      [sub_call] = AWSStub.calls(stub, @sns_path) |> Enum.filter(&(&1.body =~ "Subscribe"))
      assert sub_call.body =~ "https"
      assert sub_call.body =~ URI.encode_www_form(webhook_url)

      # Event destination included the SES event type enum.
      [ed_call] =
        AWSStub.calls(stub, "event-destinations")

      assert ed_call.body =~ "BOUNCE"
      assert ed_call.body =~ "DELIVERY_DELAY"
      assert ed_call.body =~ topic_arn
    end
  end

  describe "provision/3 idempotence" do
    test "reuses an existing, still-present topic instead of creating a new one",
         %{stub: stub, client: client} do
      existing_arn = "arn:aws:sns:us-east-1:123456789012:existing-topic"
      {:ok, source} = Tracker.update_source(%{sns_topic_arn: existing_arn})

      stub_create_configuration_set(stub)
      # GetTopicAttributes says the topic still exists.
      stub_get_topic_attributes(stub, existing_arn)
      stub_subscribe(stub, "#{existing_arn}:sub-1")

      # Register a CreateTopic stub too so we can assert it is NOT called.
      stub_create_topic(stub, "arn:aws:sns:us-east-1:123456789012:should-not-be-used")

      assert {:ok, updated} =
               SES.provision(source, "https://mail.example.com/webhooks/ses/tok", client)

      assert updated.sns_topic_arn == existing_arn

      sns_bodies = AWSStub.calls(stub, @sns_path) |> Enum.map(& &1.body)
      assert Enum.any?(sns_bodies, &(&1 =~ "GetTopicAttributes"))
      refute Enum.any?(sns_bodies, &(&1 =~ "CreateTopic"))
    end

    test "recreates the topic when the stored ARN no longer exists",
         %{stub: stub, client: client} do
      stale_arn = "arn:aws:sns:us-east-1:123456789012:gone"
      new_arn = "arn:aws:sns:us-east-1:123456789012:squatch_mail-events"
      {:ok, source} = Tracker.update_source(%{sns_topic_arn: stale_arn})

      stub_create_configuration_set(stub)
      stub_get_topic_attributes_not_found(stub)
      stub_create_topic(stub, new_arn)
      stub_subscribe(stub, "#{new_arn}:sub-1")

      assert {:ok, updated} =
               SES.provision(source, "https://mail.example.com/webhooks/ses/tok", client)

      assert updated.sns_topic_arn == new_arn

      sns_bodies = AWSStub.calls(stub, @sns_path) |> Enum.map(& &1.body)
      assert Enum.any?(sns_bodies, &(&1 =~ "CreateTopic"))
    end

    test "treats an already-existing configuration set as success",
         %{stub: stub, client: client} do
      source = Tracker.get_or_create_source()
      topic_arn = "arn:aws:sns:us-east-1:123456789012:squatch_mail-events"

      AWSStub.stub(stub, :post, @config_sets_path, fn req ->
        if req.url =~ "event-destinations" do
          {:ok, 200, ""}
        else
          {:ok, 400,
           ~s({"__type":"AlreadyExistsException","message":"Configuration set already exists."})}
        end
      end)

      stub_create_topic(stub, topic_arn)
      stub_subscribe(stub, "#{topic_arn}:sub-1")

      assert {:ok, _updated} =
               SES.provision(source, "https://mail.example.com/webhooks/ses/t", client)
    end
  end

  describe "provision/3 error path" do
    test "returns a wrapped error on auth failure", %{stub: stub, client: client} do
      source = Tracker.get_or_create_source()

      AWSStub.stub(stub, :post, @config_sets_path, fn _req ->
        {:ok, 403,
         ~s({"__type":"InvalidClientTokenId","message":"The security token included in the request is invalid."})}
      end)

      assert {:error, message} =
               SES.provision(source, "https://mail.example.com/webhooks/ses/t", client)

      assert message =~ "configuration set"
      assert message =~ "invalid AWS access key id"

      # Nothing was persisted.
      reloaded = Tracker.get_or_create_source()
      assert is_nil(reloaded.sns_topic_arn)
    end

    test "returns a wrapped error on transport failure", %{stub: stub, client: client} do
      source = Tracker.get_or_create_source()

      AWSStub.stub(stub, :post, @config_sets_path, fn _req -> {:error, :timeout} end)

      assert {:error, message} =
               SES.provision(source, "https://mail.example.com/webhooks/ses/t", client)

      assert message =~ "timed out"
    end
  end

  ## ---- sync_quota / ensure_quota_synced -------------------------------------

  describe "sync_quota/2" do
    test "persists the normalized quota and stamps quota_checked_at",
         %{stub: stub, client: client} do
      source = Tracker.get_or_create_source()
      stub_get_account(stub)

      assert {:ok, updated} = SES.sync_quota(source, client)

      assert updated.quota["max_24_hour_send"] == 50_000.0
      assert updated.quota["max_send_rate"] == 14.0
      assert updated.quota["sent_last_24_hours"] == 128.0
      assert updated.quota["sending_enabled"] == true
      assert %DateTime{} = updated.quota_checked_at
    end

    test "wraps an error response", %{stub: stub, client: client} do
      source = Tracker.get_or_create_source()

      AWSStub.stub(stub, :get, @account_path, fn _req ->
        {:ok, 500, ~s({"__type":"InternalServiceError","message":"boom"})}
      end)

      assert {:error, message} = SES.sync_quota(source, client)
      assert message =~ "quota"
      assert message =~ "HTTP 500"
    end
  end

  describe "quota_stale?/1 and ensure_quota_synced/1" do
    test "stale when never checked" do
      assert SES.quota_stale?(%Source{quota_checked_at: nil})
    end

    test "fresh within 6h, stale past it" do
      recent = DateTime.add(DateTime.utc_now(), -60, :second)
      old = DateTime.add(DateTime.utc_now(), -7 * 3600, :second)

      refute SES.quota_stale?(%Source{quota_checked_at: recent})
      assert SES.quota_stale?(%Source{quota_checked_at: old})
    end

    test "ensure_quota_synced does NOT call SES when cache is fresh", %{stub: stub} do
      {:ok, source} =
        Tracker.update_source(%{
          quota: %{"max_send_rate" => 1.0},
          quota_checked_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      assert {:ok, returned} = SES.ensure_quota_synced(source)
      assert returned.quota == %{"max_send_rate" => 1.0}
      assert AWSStub.call_count(stub, @account_path) == 0
    end
  end

  ## ---- list_identities ------------------------------------------------------

  describe "list_identities/1" do
    test "returns normalized identity maps", %{stub: stub, client: client} do
      # The list endpoint is /v2/email/identities (optionally ?NextToken=...),
      # distinct from the per-identity /v2/email/identities/<name>.
      AWSStub.stub(stub, :get, ~r"/v2/email/identities(\?|$)", fn _req ->
        {:ok, 200,
         Jason.encode!(%{
           "EmailIdentities" => [
             %{
               "IdentityName" => "example.com",
               "IdentityType" => "DOMAIN",
               "SendingEnabled" => true,
               "VerificationStatus" => "SUCCESS"
             }
           ]
         })}
      end)

      # get_email_identity for example.com
      AWSStub.stub(stub, :get, ~r"/v2/email/identities/example\.com$", fn _req ->
        {:ok, 200,
         Jason.encode!(%{
           "IdentityType" => "DOMAIN",
           "VerifiedForSendingStatus" => true,
           "VerificationStatus" => "SUCCESS",
           "DkimAttributes" => %{
             "Status" => "SUCCESS",
             "Tokens" => ["tok1", "tok2", "tok3"],
             "SigningHostedZone" => "dkim.amazonses.com"
           }
         })}
      end)

      assert {:ok, [identity]} = SES.list_identities(client)

      assert identity.identity == "example.com"
      assert identity.type == :domain
      assert identity.verified? == true
      assert identity.dkim_status == "SUCCESS"
      assert identity.dkim_tokens == ["tok1", "tok2", "tok3"]
    end

    test "follows pagination via NextToken", %{stub: stub, client: client} do
      # First list page returns a NextToken; second returns the rest.
      AWSStub.stub(stub, :get, ~r"/v2/email/identities(\?|$)", fn req ->
        if req.url =~ "NextToken" do
          {:ok, 200,
           Jason.encode!(%{
             "EmailIdentities" => [
               %{"IdentityName" => "b@example.com", "IdentityType" => "EMAIL_ADDRESS"}
             ]
           })}
        else
          {:ok, 200,
           Jason.encode!(%{
             "NextToken" => "page2",
             "EmailIdentities" => [
               %{"IdentityName" => "a.com", "IdentityType" => "DOMAIN"}
             ]
           })}
        end
      end)

      AWSStub.stub(stub, :get, ~r"/v2/email/identities/", fn req ->
        body =
          cond do
            req.url =~ "a.com" ->
              %{"IdentityType" => "DOMAIN", "DkimAttributes" => %{"Tokens" => ["t"]}}

            true ->
              %{"IdentityType" => "EMAIL_ADDRESS", "VerifiedForSendingStatus" => false}
          end

        {:ok, 200, Jason.encode!(body)}
      end)

      assert {:ok, identities} = SES.list_identities(client)
      names = Enum.map(identities, & &1.identity) |> Enum.sort()
      assert names == ["a.com", "b@example.com"]
    end
  end

  ## ---- create_identity / recheck_identity -----------------------------------

  describe "create_identity/2" do
    test "returns DKIM tokens for a new domain", %{stub: stub, client: client} do
      AWSStub.stub(stub, :post, @identities_path, fn _req ->
        {:ok, 200,
         Jason.encode!(%{
           "IdentityType" => "DOMAIN",
           "VerifiedForSendingStatus" => false,
           "DkimAttributes" => %{
             "Status" => "PENDING",
             "Tokens" => ["aaa", "bbb", "ccc"]
           }
         })}
      end)

      assert {:ok, identity} = SES.create_identity("newdomain.com", client)
      assert identity.type == :domain
      assert identity.dkim_status == "PENDING"
      assert identity.dkim_tokens == ["aaa", "bbb", "ccc"]
    end
  end

  describe "recheck_identity/2" do
    test "re-queries SES for fresh status", %{stub: stub, client: client} do
      AWSStub.stub(stub, :get, ~r"/v2/email/identities/example\.com$", fn _req ->
        {:ok, 200,
         Jason.encode!(%{
           "IdentityType" => "DOMAIN",
           "VerifiedForSendingStatus" => true,
           "VerificationStatus" => "SUCCESS",
           "DkimAttributes" => %{"Status" => "SUCCESS", "Tokens" => ["z1"]}
         })}
      end)

      assert {:ok, identity} = SES.recheck_identity("example.com", client)
      assert identity.verified? == true
      assert identity.verification_status == "SUCCESS"
      assert AWSStub.call_count(stub, "identities/example.com") == 1
    end

    test "wraps a not-found error", %{stub: stub, client: client} do
      AWSStub.stub(stub, :get, ~r"/v2/email/identities/", fn _req ->
        {:ok, 404, ~s({"__type":"NotFoundException","message":"Identity not found."})}
      end)

      assert {:error, message} = SES.recheck_identity("missing.com", client)
      assert message =~ "get identity"
      assert message =~ "HTTP 404"
    end
  end

  ## ---- dns_records_for (pure) -----------------------------------------------

  describe "dns_records_for/1" do
    test "produces the SES Easy DKIM CNAMEs plus SPF and DMARC for a domain" do
      identity = %{
        identity: "example.com",
        type: :domain,
        dkim_tokens: ["t0k3n1", "t0k3n2", "t0k3n3"],
        dkim_signing_hosted_zone: "dkim.amazonses.com"
      }

      records = SES.dns_records_for(identity)

      cnames = Enum.filter(records, &(&1.purpose == :dkim))
      assert length(cnames) == 3

      assert %{
               type: :cname,
               name: "t0k3n1._domainkey.example.com",
               value: "t0k3n1.dkim.amazonses.com",
               purpose: :dkim
             } in cnames

      spf = Enum.find(records, &(&1.purpose == :spf))
      assert spf.type == :txt
      assert spf.name == "example.com"
      assert spf.value == "v=spf1 include:amazonses.com ~all"

      dmarc = Enum.find(records, &(&1.purpose == :dmarc))
      assert dmarc.type == :txt
      assert dmarc.name == "_dmarc.example.com"
    end

    test "uses the region-specific SigningHostedZone when present" do
      identity = %{
        identity: "example.com",
        type: :domain,
        dkim_tokens: ["abc"],
        dkim_signing_hosted_zone: "a31d.dkim.us-west-2.amazonses.com"
      }

      [cname | _] = SES.dns_records_for(identity)
      assert cname.value == "abc.a31d.dkim.us-west-2.amazonses.com"
    end

    test "falls back to the default hosted zone when none is provided" do
      identity = %{identity: "example.com", type: :domain, dkim_tokens: ["abc"]}

      [cname | _] = SES.dns_records_for(identity)
      assert cname.value == "abc.dkim.amazonses.com"
    end

    test "returns no records for an email-address identity" do
      assert SES.dns_records_for(%{identity: "me@example.com", type: :email}) == []
    end
  end

  ## ---- stub helpers ---------------------------------------------------------

  # Config-set create and event-destination create share the same path; a single
  # matcher answers both (SES returns 200 with an empty body for each).
  defp stub_create_configuration_set(stub) do
    AWSStub.stub(stub, :post, @config_sets_path, fn _req -> {:ok, 200, ""} end)
  end

  defp stub_create_topic(stub, arn) do
    AWSStub.stub(stub, :post, @sns_path, fn req ->
      if req.body =~ "Action=CreateTopic" do
        {:ok, 200,
         """
         <CreateTopicResponse xmlns="http://sns.amazonaws.com/doc/2010-03-31/">
           <CreateTopicResult><TopicArn>#{arn}</TopicArn></CreateTopicResult>
         </CreateTopicResponse>
         """}
      else
        :pass
      end
    end)
  end

  defp stub_get_topic_attributes(stub, arn) do
    AWSStub.stub(stub, :post, @sns_path, fn req ->
      if req.body =~ "Action=GetTopicAttributes" do
        {:ok, 200,
         """
         <GetTopicAttributesResponse xmlns="http://sns.amazonaws.com/doc/2010-03-31/">
           <GetTopicAttributesResult>
             <Attributes><entry><key>TopicArn</key><value>#{arn}</value></entry></Attributes>
           </GetTopicAttributesResult>
         </GetTopicAttributesResponse>
         """}
      else
        :pass
      end
    end)
  end

  defp stub_get_topic_attributes_not_found(stub) do
    AWSStub.stub(stub, :post, @sns_path, fn req ->
      if req.body =~ "Action=GetTopicAttributes" do
        {:ok, 404,
         """
         <ErrorResponse><Error><Code>NotFound</Code>
         <Message>Topic does not exist</Message></Error></ErrorResponse>
         """}
      else
        :pass
      end
    end)
  end

  defp stub_subscribe(stub, sub_arn) do
    AWSStub.stub(stub, :post, @sns_path, fn req ->
      if req.body =~ "Action=Subscribe" do
        {:ok, 200,
         """
         <SubscribeResponse xmlns="http://sns.amazonaws.com/doc/2010-03-31/">
           <SubscribeResult><SubscriptionArn>#{sub_arn}</SubscriptionArn></SubscribeResult>
         </SubscribeResponse>
         """}
      else
        :pass
      end
    end)
  end

  defp stub_get_account(stub) do
    AWSStub.stub(stub, :get, @account_path, fn _req ->
      {:ok, 200,
       Jason.encode!(%{
         "SendingEnabled" => true,
         "ProductionAccessEnabled" => true,
         "EnforcementStatus" => "HEALTHY",
         "SendQuota" => %{
           "Max24HourSend" => 50_000.0,
           "MaxSendRate" => 14.0,
           "SentLast24Hours" => 128.0
         }
       })}
    end)
  end

  ## ---- misc -----------------------------------------------------------------

  # Temporarily sets/unsets env vars for the duration of `fun`.
  defp with_env(vars, fun) do
    originals =
      Map.new(vars, fn {key, _} -> {key, System.get_env(key)} end)

    Enum.each(vars, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    try do
      fun.()
    after
      Enum.each(originals, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
