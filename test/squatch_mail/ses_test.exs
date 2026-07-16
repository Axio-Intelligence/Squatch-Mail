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

      assert {:ok, client} = SES.client(source)
      assert client.access_key_id == "AKIASTATIC"
      assert client.secret_access_key == "shhh"
      assert client.region == "eu-west-1"
      assert client.http_client == {AWS.HTTPClient.Finch, finch_name: SquatchMail.Finch}
    end

    test "returns {:error, :missing_credentials} for static mode with missing keys, without raising" do
      source = %Source{credentials_mode: "static", region: "us-east-1"}

      assert SES.client(source) == {:error, :missing_credentials}
    end

    test "returns {:error, :missing_credentials} for static mode with a blank (whitespace) secret" do
      source = %Source{
        credentials_mode: "static",
        region: "us-east-1",
        access_key_id: "AKIASTATIC",
        secret_access_key: "   "
      }

      assert SES.client(source) == {:error, :missing_credentials}
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
          assert {:ok, client} = SES.client(source)
          assert client.access_key_id == "AKIAENV"
          assert client.secret_access_key == "envsecret"
          assert client.session_token == "token123"
          assert client.region == "us-west-2"
          assert client.http_client == {AWS.HTTPClient.Finch, finch_name: SquatchMail.Finch}
        end
      )
    end

    test "returns {:error, :missing_credentials} for ambient mode with no env credentials, without raising" do
      source = %Source{credentials_mode: "ambient", region: "us-east-1"}

      with_env(%{"AWS_ACCESS_KEY_ID" => nil, "AWS_SECRET_ACCESS_KEY" => nil}, fn ->
        assert SES.client(source) == {:error, :missing_credentials}
      end)
    end
  end

  ## ---- unconfigured-source path (no raise, error propagates) ----------------

  describe "public functions against an unconfigured (credential-less) source" do
    setup do
      # Ambient mode (the Source default) with no AWS env vars present is
      # exactly the state of a freshly-installed host that hasn't visited
      # Base Camp yet — this must never crash a LiveView mount/handle_event.
      {:ok, _source} =
        Tracker.update_source(%{credentials_mode: "ambient", region: "us-east-1"})

      :ok
    end

    test "client/0 returns {:error, :missing_credentials}" do
      with_env(%{"AWS_ACCESS_KEY_ID" => nil, "AWS_SECRET_ACCESS_KEY" => nil}, fn ->
        assert SES.client() == {:error, :missing_credentials}
      end)
    end

    test "sync_quota/0 propagates {:error, :missing_credentials} instead of raising" do
      with_env(%{"AWS_ACCESS_KEY_ID" => nil, "AWS_SECRET_ACCESS_KEY" => nil}, fn ->
        assert SES.sync_quota() == {:error, :missing_credentials}
      end)
    end

    test "ensure_quota_synced/1 propagates {:error, :missing_credentials} when stale" do
      source = Tracker.get_or_create_source()

      with_env(%{"AWS_ACCESS_KEY_ID" => nil, "AWS_SECRET_ACCESS_KEY" => nil}, fn ->
        assert SES.ensure_quota_synced(source) == {:error, :missing_credentials}
      end)
    end

    test "list_identities/0 propagates {:error, :missing_credentials} instead of raising" do
      with_env(%{"AWS_ACCESS_KEY_ID" => nil, "AWS_SECRET_ACCESS_KEY" => nil}, fn ->
        assert SES.list_identities() == {:error, :missing_credentials}
      end)
    end

    test "create_identity/1 propagates {:error, :missing_credentials} instead of raising" do
      with_env(%{"AWS_ACCESS_KEY_ID" => nil, "AWS_SECRET_ACCESS_KEY" => nil}, fn ->
        assert SES.create_identity("example.com") == {:error, :missing_credentials}
      end)
    end

    test "recheck_identity/1 propagates {:error, :missing_credentials} instead of raising" do
      with_env(%{"AWS_ACCESS_KEY_ID" => nil, "AWS_SECRET_ACCESS_KEY" => nil}, fn ->
        assert SES.recheck_identity("example.com") == {:error, :missing_credentials}
      end)
    end

    test "provision/1 propagates {:error, :missing_credentials} instead of raising" do
      with_env(%{"AWS_ACCESS_KEY_ID" => nil, "AWS_SECRET_ACCESS_KEY" => nil}, fn ->
        assert SES.provision("https://example.com/webhooks/sns/tok") ==
                 {:error, :missing_credentials}
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

  ## ---- structured AWS error matching (already_exists?/not_found?) -----------

  describe "structured AWS error matching" do
    test "SNS XML NotFound code is treated as not-found even with an unrelated Message body",
         %{stub: stub, client: client} do
      stale_arn = "arn:aws:sns:us-east-1:123456789012:gone"
      new_arn = "arn:aws:sns:us-east-1:123456789012:squatch_mail-events"
      {:ok, source} = Tracker.update_source(%{sns_topic_arn: stale_arn})

      stub_create_configuration_set(stub)

      AWSStub.stub(stub, :post, @sns_path, fn req ->
        cond do
          req.body =~ "Action=GetTopicAttributes" ->
            {:ok, 404,
             """
             <ErrorResponse><Error><Code>NotFound</Code>
             <Message>Topic does not exist</Message></Error></ErrorResponse>
             """}

          true ->
            :pass
        end
      end)

      stub_create_topic(stub, new_arn)
      stub_subscribe(stub, "#{new_arn}:sub-1")

      assert {:ok, updated} =
               SES.provision(source, "https://mail.example.com/webhooks/ses/tok", client)

      assert updated.sns_topic_arn == new_arn
    end

    test "a 400 validation error whose message happens to mention 'not found' is NOT treated as not-found",
         %{stub: stub, client: client} do
      # This is exactly the false-positive the old substring-matching code was
      # vulnerable to: the error CODE is ValidationException (a real failure,
      # not "the topic doesn't exist"), but the human-readable message text
      # contains the words "was not found" incidentally (e.g. referencing an
      # unrelated IAM role). Structured matching on the code must not treat
      # this as the idempotent not-found case.
      stale_arn = "arn:aws:sns:us-east-1:123456789012:gone"
      {:ok, source} = Tracker.update_source(%{sns_topic_arn: stale_arn})

      stub_create_configuration_set(stub)

      AWSStub.stub(stub, :post, @sns_path, fn req ->
        if req.body =~ "Action=GetTopicAttributes" do
          {:ok, 400,
           """
           <ErrorResponse><Error><Code>ValidationException</Code>
           <Message>The specified execution role was not found</Message></Error></ErrorResponse>
           """}
        else
          :pass
        end
      end)

      assert {:error, message} =
               SES.provision(source, "https://mail.example.com/webhooks/ses/tok", client)

      assert message =~ "look up SNS topic"

      # Nothing was persisted — we correctly did NOT treat this as "go ahead
      # and create a new topic".
      reloaded = Tracker.get_or_create_source()
      assert reloaded.sns_topic_arn == stale_arn
    end

    test "a 400 error whose message happens to mention 'already exists' but has an unrelated code is NOT treated as already-exists",
         %{stub: stub, client: client} do
      source = Tracker.get_or_create_source()

      AWSStub.stub(stub, :post, @config_sets_path, fn req ->
        if req.url =~ "event-destinations" do
          {:ok, 200, ""}
        else
          {:ok, 400,
           ~s({"__type":"ValidationException","message":"A resource with that ARN already exists in another account and cannot be reused."})}
        end
      end)

      assert {:error, message} =
               SES.provision(source, "https://mail.example.com/webhooks/ses/t", client)

      assert message =~ "configuration set"

      reloaded = Tracker.get_or_create_source()
      assert is_nil(reloaded.sns_topic_arn)
      assert is_nil(reloaded.configuration_set)
    end

    test "falls back to status-code semantics (409) when the body doesn't parse as JSON or XML",
         %{stub: stub, client: client} do
      source = Tracker.get_or_create_source()

      AWSStub.stub(stub, :post, @config_sets_path, fn req ->
        if req.url =~ "event-destinations" do
          {:ok, 200, ""}
        else
          {:ok, 409, "not valid json or xml, just a plain string"}
        end
      end)

      topic_arn = "arn:aws:sns:us-east-1:123456789012:squatch_mail-events"
      stub_create_topic(stub, topic_arn)
      stub_subscribe(stub, "#{topic_arn}:sub-1")

      assert {:ok, _updated} =
               SES.provision(source, "https://mail.example.com/webhooks/ses/t", client)
    end

    test "falls back to status-code semantics (404) when the body doesn't parse as JSON or XML",
         %{stub: stub, client: client} do
      stale_arn = "arn:aws:sns:us-east-1:123456789012:gone"
      new_arn = "arn:aws:sns:us-east-1:123456789012:squatch_mail-events"
      {:ok, source} = Tracker.update_source(%{sns_topic_arn: stale_arn})

      stub_create_configuration_set(stub)

      AWSStub.stub(stub, :post, @sns_path, fn req ->
        if req.body =~ "Action=GetTopicAttributes" do
          {:ok, 404, "plain text, not xml"}
        else
          :pass
        end
      end)

      stub_create_topic(stub, new_arn)
      stub_subscribe(stub, "#{new_arn}:sub-1")

      assert {:ok, updated} =
               SES.provision(source, "https://mail.example.com/webhooks/ses/tok", client)

      assert updated.sns_topic_arn == new_arn
    end

    test "treats an HTTP-400 message-only 'already exists' configuration set as success (SESv2)",
         %{stub: stub, client: client} do
      # The exact production shape that broke re-provision: SESv2 returns HTTP
      # 400 with a bare `{"message": "... already exists."}` body — no
      # `__type`, no `x-amzn-errortype` header — so structured detection finds
      # no code and the status is 400 (not 409). The scoped message backstop in
      # `ensure_configuration_set` must still treat this idempotent create as
      # success.
      source = Tracker.get_or_create_source()
      topic_arn = "arn:aws:sns:us-east-1:123456789012:squatch_mail-events"

      AWSStub.stub(stub, :post, @config_sets_path, fn req ->
        if req.url =~ "event-destinations" do
          {:ok, 200, ""}
        else
          {:ok, 400, ~s({"message":"Configuration set squatch_mail-events already exists."})}
        end
      end)

      stub_create_topic(stub, topic_arn)
      stub_subscribe(stub, "#{topic_arn}:sub-1")

      assert {:ok, _updated} =
               SES.provision(source, "https://mail.example.com/webhooks/ses/t", client)
    end

    test "recognizes an 'already exists' conflict from the x-amzn-errortype header",
         %{stub: stub, client: client} do
      # Even when SESv2 omits `__type` from the body, the `aws` client surfaces
      # the error type in the `x-amzn-errortype` response header (here with the
      # `:`-delimited suffix AWS sometimes appends, which we strip). The body
      # here says nothing about "already exists" — only the header does — so
      # this isolates the header path from the message backstop.
      source = Tracker.get_or_create_source()
      topic_arn = "arn:aws:sns:us-east-1:123456789012:squatch_mail-events"

      AWSStub.stub(stub, :post, @config_sets_path, fn req ->
        if req.url =~ "event-destinations" do
          {:ok, 200, ""}
        else
          {:ok, 400, ~s({"message":"bad request"}),
           [{"x-amzn-errortype", "AlreadyExistsException:http://internal.amazon.com/coral/"}]}
        end
      end)

      stub_create_topic(stub, topic_arn)
      stub_subscribe(stub, "#{topic_arn}:sub-1")

      assert {:ok, _updated} =
               SES.provision(source, "https://mail.example.com/webhooks/ses/t", client)
    end

    test "the shared x-amzn-errortype extraction also powers not_found? (recreates the topic)",
         %{stub: stub, client: client} do
      # Mirror of the already-exists header case: a topic lookup whose error
      # type arrives only in the `x-amzn-errortype` header is still recognized
      # as "not found", so provision recreates the topic rather than aborting.
      stale_arn = "arn:aws:sns:us-east-1:123456789012:gone"
      new_arn = "arn:aws:sns:us-east-1:123456789012:squatch_mail-events"
      {:ok, source} = Tracker.update_source(%{sns_topic_arn: stale_arn})

      stub_create_configuration_set(stub)

      AWSStub.stub(stub, :post, @sns_path, fn req ->
        if req.body =~ "Action=GetTopicAttributes" do
          {:ok, 400, ~s({"message":"whatever"}), [{"x-amzn-errortype", "NotFoundException"}]}
        else
          :pass
        end
      end)

      stub_create_topic(stub, new_arn)
      stub_subscribe(stub, "#{new_arn}:sub-1")

      assert {:ok, updated} =
               SES.provision(source, "https://mail.example.com/webhooks/ses/tok", client)

      assert updated.sns_topic_arn == new_arn
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

  ## ---- check_dns (live, injectable resolver) ---------------------------------

  describe "check_dns/2" do
    setup do
      identity = %{
        identity: "example.com",
        type: :domain,
        dkim_tokens: ["t0k3n1", "t0k3n2"],
        dkim_signing_hosted_zone: "dkim.amazonses.com"
      }

      %{records: SES.dns_records_for(identity)}
    end

    test "passes every record when the resolver returns exactly the expected values", %{
      records: records
    } do
      resolver = fn name, :in, type -> matching_resolver(name, type) end

      results = SES.check_dns(records, resolver)

      assert length(results) == length(records)
      assert Enum.all?(results, &(&1.status == :pass))
      assert Enum.all?(results, &is_list(&1.found))
    end

    test "flags a CNAME as :warn when it resolves to something else", %{records: records} do
      resolver = fn
        ~c"t0k3n1._domainkey.example.com", :in, :cname ->
          [~c"someone-elses-value.dkim.amazonses.com"]

        name, :in, type ->
          matching_resolver(name, type)
      end

      results = SES.check_dns(records, resolver)
      cname = Enum.find(results, &(&1.name == "t0k3n1._domainkey.example.com"))

      assert cname.status == :warn
      assert cname.found == ["someone-elses-value.dkim.amazonses.com"]
    end

    test "flags a record as :missing when the resolver returns no answers", %{records: records} do
      resolver = fn
        ~c"t0k3n1._domainkey.example.com", :in, :cname -> []
        name, :in, type -> matching_resolver(name, type)
      end

      results = SES.check_dns(records, resolver)
      cname = Enum.find(results, &(&1.name == "t0k3n1._domainkey.example.com"))

      assert cname.status == :missing
      assert cname.found == []
    end

    test "TXT match is a substring check, so an unrelated coexisting TXT record still passes",
         %{records: records} do
      resolver = fn
        ~c"example.com", :in, :txt ->
          [[~c"some-other-verification=abc123"], [~c"v=spf1 include:amazonses.com ~all"]]

        name, :in, type ->
          matching_resolver(name, type)
      end

      results = SES.check_dns(records, resolver)
      spf = Enum.find(results, &(&1.purpose == :spf))

      assert spf.status == :pass
      assert length(spf.found) == 2
    end

    test "flags SPF as :warn when only an unrelated TXT record is present", %{records: records} do
      resolver = fn
        ~c"example.com", :in, :txt -> [[~c"some-other-verification=abc123"]]
        name, :in, type -> matching_resolver(name, type)
      end

      results = SES.check_dns(records, resolver)
      spf = Enum.find(results, &(&1.purpose == :spf))

      assert spf.status == :warn
    end

    test "concatenates multi-segment TXT answers before matching", %{records: records} do
      # A single TXT record can be split across multiple <=255-byte strings;
      # :inet_res.lookup/3 returns each TXT record as a list of those segments.
      long_value = "v=spf1 include:amazonses.com ~all"
      {first, second} = String.split_at(long_value, 10)

      resolver = fn
        ~c"example.com", :in, :txt ->
          [[String.to_charlist(first), String.to_charlist(second)]]

        name, :in, type ->
          matching_resolver(name, type)
      end

      results = SES.check_dns(records, resolver)
      spf = Enum.find(results, &(&1.purpose == :spf))

      assert spf.status == :pass
    end

    test "a raising resolver is treated as :missing rather than crashing the caller", %{
      records: records
    } do
      resolver = fn _name, :in, _type -> raise "nameserver unreachable" end

      results = SES.check_dns(records, resolver)

      assert Enum.all?(results, &(&1.status == :missing))
      assert Enum.all?(results, &(&1.found == []))
    end

    test "defaults to :inet_res.lookup/3 when no resolver is given" do
      # Smoke test only: we don't assert on the outcome (real DNS, may be
      # :pass/:warn/:missing depending on environment/network), just that the
      # 3-arg default doesn't raise and returns the expected shape.
      record = %{
        type: :txt,
        name: "example.com",
        value: "v=spf1 include:amazonses.com ~all",
        purpose: :spf
      }

      results = SES.check_dns([record])

      assert [%{status: status, found: found}] = results
      assert status in [:pass, :warn, :missing]
      assert is_list(found)
    end

    # Answers exactly what dns_records_for/1 for the fixture identity expects,
    # for any (name, type) pair not overridden by a more specific clause above.
    defp matching_resolver(~c"t0k3n1._domainkey.example.com", :cname),
      do: [~c"t0k3n1.dkim.amazonses.com"]

    defp matching_resolver(~c"t0k3n2._domainkey.example.com", :cname),
      do: [~c"t0k3n2.dkim.amazonses.com"]

    defp matching_resolver(~c"example.com", :txt),
      do: [[~c"v=spf1 include:amazonses.com ~all"]]

    defp matching_resolver(~c"_dmarc.example.com", :txt), do: [[~c"v=DMARC1; p=none;"]]
    defp matching_resolver(_name, _type), do: []
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
