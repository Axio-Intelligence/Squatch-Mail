defmodule SquatchMail.SES do
  @moduledoc """
  Amazon SES v2 / SNS integration for SquatchMail.

  This module owns every call SquatchMail makes to AWS (via the `aws` package's
  `AWS.SESv2` and `AWS.SNS` clients) and the interpretation of their responses.
  It does **not** own persistence of the `SquatchMail.Source` row — reading and
  writing that goes through `SquatchMail.Tracker.get_or_create_source/0` and
  `SquatchMail.Tracker.update_source/1`.

  It provides four capabilities that back the dashboard's "Connect SES" flow:

    * **One-click provisioning** (`provision/2`) — idempotently create (or reuse)
      a configuration set, an SNS topic, an HTTPS subscription to our webhook
      URL, and a configuration-set event destination pointing at that topic.
    * **Quota sync** (`sync_quota/1`, `ensure_quota_synced/1`) — read the SES
      account sending quota and cache it on the source for 6 hours.
    * **Identity management** (`list_identities/1`, `create_identity/2`,
      `recheck_identity/2`) — list sending identities with their verification and
      DKIM status, add a new domain/email identity, and re-query a single
      identity's live status.
    * **DNS record guidance** (`dns_records_for/1`) — a pure function turning a
      normalized identity map into the CNAME/TXT records a user must publish.

  ## Building the AWS client

  Every function accepts an optional `%AWS.Client{}` (see `client/0` and
  `client/1`) so callers — including tests — can inject a client with a stubbed
  HTTP backend. When omitted, the client is built from the current source row.

  ### Credentials / "ambient" mode

  `SquatchMail.Source.credentials_mode` is either `"static"` or `"ambient"`:

    * `"static"` — the source stores an explicit `access_key_id` /
      `secret_access_key` pair; the client is built from those.
    * `"ambient"` — no keys are stored in our database. We read
      `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` from
      the environment (the vendored `aws` package's `AWS.Client.create/1`
      behaviour). This deliberately does **not** perform EC2 IMDSv2 / ECS task
      role resolution — that is a documented follow-up. A host that runs on an
      instance/task role and wants those credentials used should either export
      them into the environment or inject its own `%AWS.Client{}` via the
      optional client argument / a configured client factory (see
      `SquatchMail.SES.client/1`).

  Whichever path is taken, the client's HTTP backend is wired to the shared
  `SquatchMail.Finch` pool so we never pull in hackney.
  """

  require Logger

  alias SquatchMail.{Config, Source, Tracker}

  @typedoc "A normalized identity as returned by `list_identities/1`."
  @type identity :: %{
          identity: String.t(),
          type: :domain | :email,
          verified?: boolean(),
          verification_status: String.t() | nil,
          dkim_status: String.t() | nil,
          dkim_tokens: [String.t()],
          dkim_signing_hosted_zone: String.t() | nil,
          sending_enabled?: boolean() | nil
        }

  @typedoc "A single DNS record the user must publish, from `dns_records_for/1`."
  @type dns_record :: %{
          type: :cname | :txt,
          name: String.t(),
          value: String.t(),
          purpose: :dkim | :spf | :dmarc
        }

  # SES v2 EventType enum accepted by MatchingEventTypes. Verified against the
  # AWS SES API reference (EventDestinationDefinition):
  # SEND | REJECT | BOUNCE | COMPLAINT | DELIVERY | OPEN | CLICK |
  # RENDERING_FAILURE | DELIVERY_DELAY | SUBSCRIPTION.
  @event_types ~w(SEND REJECT BOUNCE COMPLAINT DELIVERY OPEN CLICK
                  RENDERING_FAILURE DELIVERY_DELAY SUBSCRIPTION)

  # Default SES Easy DKIM hosted zone used to build CNAME record values when the
  # API response doesn't carry a region/cell-specific SigningHostedZone. The
  # authoritative value is `DkimAttributes.SigningHostedZone` when present.
  @default_dkim_hosted_zone "dkim.amazonses.com"

  # Six hours, in seconds, for the quota cache freshness window.
  @quota_ttl_seconds 6 * 60 * 60

  ## ---------------------------------------------------------------------------
  ## Client construction
  ## ---------------------------------------------------------------------------

  @doc """
  Builds an `%AWS.Client{}` from the current source row.

  Loads the source via `SquatchMail.Tracker.get_or_create_source/0`.
  """
  @spec client() :: AWS.Client.t()
  def client, do: client(Tracker.get_or_create_source())

  @doc """
  Builds an `%AWS.Client{}` from the given source.

  For `credentials_mode: "static"` the source's `access_key_id` /
  `secret_access_key` are used. For `"ambient"` the standard AWS environment
  variables are read (see the moduledoc "Credentials" section). The client's
  HTTP backend is always the shared `SquatchMail.Finch` pool.

  Raises a `RuntimeError` with an actionable message when required credentials
  are missing.
  """
  @spec client(Source.t()) :: AWS.Client.t()
  def client(%Source{credentials_mode: "static"} = source) do
    if blank?(source.access_key_id) or blank?(source.secret_access_key) do
      raise """
      SquatchMail source is in "static" credentials mode but is missing an \
      access_key_id and/or secret_access_key. Add the keys on the source, or \
      switch credentials_mode to "ambient" to read them from the environment.
      """
    end

    source.access_key_id
    |> AWS.Client.create(source.secret_access_key, source.region)
    |> put_finch()
  end

  def client(%Source{credentials_mode: "ambient"} = source) do
    region = source.region || "us-east-1"

    access_key_id = System.get_env("AWS_ACCESS_KEY_ID")
    secret_access_key = System.get_env("AWS_SECRET_ACCESS_KEY")
    token = System.get_env("AWS_SESSION_TOKEN")

    if blank?(access_key_id) or blank?(secret_access_key) do
      raise """
      SquatchMail source is in "ambient" credentials mode but neither \
      AWS_ACCESS_KEY_ID nor AWS_SECRET_ACCESS_KEY is set in the environment. \
      Export static AWS credentials, switch the source to "static" mode with \
      explicit keys, or inject a pre-built %AWS.Client{} into the SquatchMail.SES \
      function you're calling. (EC2/ECS instance-role resolution is not yet \
      implemented — see SquatchMail.SES moduledoc.)
      """
    end

    access_key_id
    |> AWS.Client.create(secret_access_key, token, region)
    |> put_finch()
  end

  defp put_finch(%AWS.Client{} = client) do
    AWS.Client.put_http_client(client, {AWS.HTTPClient.Finch, finch_name: SquatchMail.Finch})
  end

  ## ---------------------------------------------------------------------------
  ## Provisioning ("Connect SES")
  ## ---------------------------------------------------------------------------

  @doc """
  Idempotently provisions SES event publishing for the current source.

  See `provision/3`. Builds the client from the source itself.
  """
  @spec provision(String.t()) :: {:ok, Source.t()} | {:error, term()}
  def provision(webhook_url) when is_binary(webhook_url) do
    source = Tracker.get_or_create_source()
    provision(source, webhook_url, client(source))
  end

  @doc """
  Idempotently provisions SES event publishing for `source`.

  `webhook_url` must be the full, publicly-reachable HTTPS URL of SquatchMail's
  SNS webhook endpoint — typically `https://<host>/webhooks/ses/<webhook_token>`.
  This module does **not** compute the host's public base URL (there is no
  router/endpoint at this layer); the dashboard/router layer is responsible for
  building it and passing it in.

  The flow, each step a no-op if already satisfied:

    1. Create (or reuse) a configuration set named `source.configuration_set`
       (a default derived from the configured prefix is used when blank).
    2. Create (or reuse) an SNS topic. A stored `source.sns_topic_arn` is reused
       only after confirming the topic still exists (`GetTopicAttributes`);
       otherwise a new topic is created.
    3. Subscribe `webhook_url` to the topic over HTTPS.
    4. Create the configuration-set event destination pointing at the topic for
       all relevant SES event types.

  On success the resolved `configuration_set` and `sns_topic_arn` are persisted
  back onto the source and `{:ok, source}` is returned. On failure a wrapped,
  actionable `{:error, reason}` is returned (never a raw AWS error map).
  """
  @spec provision(Source.t(), String.t(), AWS.Client.t()) ::
          {:ok, Source.t()} | {:error, term()}
  def provision(%Source{} = source, webhook_url, %AWS.Client{} = client)
      when is_binary(webhook_url) do
    config_set = configuration_set_name(source)

    with :ok <- ensure_configuration_set(client, config_set),
         {:ok, topic_arn} <- ensure_topic(client, source),
         {:ok, _sub} <- ensure_subscription(client, topic_arn, webhook_url),
         :ok <- ensure_event_destination(client, config_set, topic_arn),
         {:ok, updated} <-
           Tracker.update_source(%{
             configuration_set: config_set,
             sns_topic_arn: topic_arn
           }) do
      {:ok, updated}
    end
  end

  @doc false
  @spec configuration_set_name(Source.t()) :: String.t()
  def configuration_set_name(%Source{configuration_set: cs}) when is_binary(cs) do
    case String.trim(cs) do
      "" -> default_configuration_set_name()
      name -> name
    end
  end

  def configuration_set_name(%Source{}), do: default_configuration_set_name()

  defp default_configuration_set_name do
    prefix = Config.prefix()
    "#{prefix}-events"
  end

  # Creates the configuration set, treating an "already exists" conflict as
  # success (idempotent).
  defp ensure_configuration_set(client, config_set) do
    input = %{"ConfigurationSetName" => config_set}

    case AWS.SESv2.create_configuration_set(client, input) do
      {:ok, _body, _resp} ->
        :ok

      {:error, {:unexpected_response, resp}} = error ->
        if already_exists?(resp) do
          :ok
        else
          wrap(error, "create configuration set #{inspect(config_set)}")
        end

      other ->
        wrap(other, "create configuration set #{inspect(config_set)}")
    end
  end

  # Reuses source.sns_topic_arn when the topic still exists; otherwise creates a
  # new topic. CreateTopic is itself idempotent by name in SNS, so a name-based
  # create is safe even when we can't reuse.
  defp ensure_topic(client, %Source{sns_topic_arn: arn} = source)
       when is_binary(arn) and arn != "" do
    case AWS.SNS.get_topic_attributes(client, %{"TopicArn" => arn}) do
      {:ok, _body, _resp} ->
        {:ok, arn}

      {:error, {:unexpected_response, resp}} ->
        if not_found?(resp) do
          create_topic(client, source)
        else
          wrap({:error, {:unexpected_response, resp}}, "look up SNS topic #{inspect(arn)}")
        end

      other ->
        wrap(other, "look up SNS topic #{inspect(arn)}")
    end
  end

  defp ensure_topic(client, source), do: create_topic(client, source)

  defp create_topic(client, %Source{} = source) do
    name = topic_name(source)

    case AWS.SNS.create_topic(client, %{"Name" => name}) do
      {:ok, body, _resp} ->
        case extract_topic_arn(body) do
          nil -> {:error, "SNS CreateTopic succeeded but returned no TopicArn"}
          topic_arn -> {:ok, topic_arn}
        end

      other ->
        wrap(other, "create SNS topic #{inspect(name)}")
    end
  end

  defp topic_name(%Source{configuration_set: cs}) when is_binary(cs) and cs != "" do
    sanitize_topic_name(cs)
  end

  defp topic_name(%Source{}), do: sanitize_topic_name(default_configuration_set_name())

  # SNS topic names allow [A-Za-z0-9_-] only, up to 256 chars.
  defp sanitize_topic_name(name) do
    name
    |> String.replace(~r/[^A-Za-z0-9_-]/, "-")
    |> String.slice(0, 256)
  end

  # Subscribes the webhook URL. SNS Subscribe is idempotent for the same
  # protocol+endpoint (returns the existing subscription's ARN, or
  # "pending confirmation").
  defp ensure_subscription(client, topic_arn, webhook_url) do
    input = %{
      "TopicArn" => topic_arn,
      "Protocol" => subscription_protocol(webhook_url),
      "Endpoint" => webhook_url,
      # Deliver the raw SES event JSON without SNS's own envelope wrapping? No —
      # we want the SNS envelope so the webhook layer can verify signatures.
      "ReturnSubscriptionArn" => "true"
    }

    case AWS.SNS.subscribe(client, input) do
      {:ok, body, _resp} -> {:ok, extract_subscription_arn(body)}
      other -> wrap(other, "subscribe #{inspect(webhook_url)} to topic")
    end
  end

  defp subscription_protocol("https://" <> _), do: "https"
  defp subscription_protocol("http://" <> _), do: "http"
  defp subscription_protocol(_), do: "https"

  defp ensure_event_destination(client, config_set, topic_arn) do
    input = %{
      "EventDestinationName" => event_destination_name(),
      "EventDestination" => %{
        "Enabled" => true,
        "MatchingEventTypes" => @event_types,
        "SnsDestination" => %{"TopicArn" => topic_arn}
      }
    }

    case AWS.SESv2.create_configuration_set_event_destination(client, config_set, input) do
      {:ok, _body, _resp} ->
        :ok

      {:error, {:unexpected_response, resp}} = error ->
        if already_exists?(resp) do
          :ok
        else
          wrap(error, "create event destination on #{inspect(config_set)}")
        end

      other ->
        wrap(other, "create event destination on #{inspect(config_set)}")
    end
  end

  defp event_destination_name, do: "#{Config.prefix()}-sns"

  ## ---------------------------------------------------------------------------
  ## Quota sync
  ## ---------------------------------------------------------------------------

  @doc """
  Syncs the SES sending quota onto the current source, ignoring the cache.

  See `sync_quota/2`.
  """
  @spec sync_quota() :: {:ok, Source.t()} | {:error, term()}
  def sync_quota do
    source = Tracker.get_or_create_source()
    sync_quota(source, client(source))
  end

  @doc """
  Fetches the SES account sending quota and persists it onto the source.

  Calls `AWS.SESv2.get_account/2`, extracts the sending-enabled flag and the
  `Max24HourSend` / `MaxSendRate` / `SentLast24Hours` figures into the source's
  `quota` map, and stamps `quota_checked_at`. Returns `{:ok, source}` or a
  wrapped `{:error, reason}`.
  """
  @spec sync_quota(Source.t(), AWS.Client.t()) :: {:ok, Source.t()} | {:error, term()}
  def sync_quota(%Source{} = _source, %AWS.Client{} = client) do
    case AWS.SESv2.get_account(client) do
      {:ok, body, _resp} ->
        Tracker.update_source(%{
          quota: normalize_quota(body),
          quota_checked_at: DateTime.utc_now()
        })

      other ->
        wrap(other, "get SES account quota")
    end
  end

  @doc """
  Returns the source with a fresh quota, syncing from SES only when stale.

  The cache is considered fresh for 6 hours. When `quota_checked_at` is `nil` or
  older than 6 hours, this calls `sync_quota/2`; otherwise it returns the
  current source unchanged in an `{:ok, source}` tuple. This is the ticket's
  "cache 6h" behaviour.
  """
  @spec ensure_quota_synced(Source.t() | nil) :: {:ok, Source.t()} | {:error, term()}
  def ensure_quota_synced(source \\ nil)

  def ensure_quota_synced(nil), do: ensure_quota_synced(Tracker.get_or_create_source())

  def ensure_quota_synced(%Source{} = source) do
    if quota_stale?(source) do
      sync_quota(source, client(source))
    else
      {:ok, source}
    end
  end

  @doc """
  Returns `true` when the source's cached quota is missing or older than 6h.
  """
  @spec quota_stale?(Source.t()) :: boolean()
  def quota_stale?(%Source{quota_checked_at: nil}), do: true

  def quota_stale?(%Source{quota_checked_at: %DateTime{} = checked_at}) do
    DateTime.diff(DateTime.utc_now(), checked_at, :second) >= @quota_ttl_seconds
  end

  defp normalize_quota(body) when is_map(body) do
    send_quota = Map.get(body, "SendQuota", %{})

    %{
      "sending_enabled" => Map.get(body, "SendingEnabled"),
      "production_access_enabled" => Map.get(body, "ProductionAccessEnabled"),
      "enforcement_status" => Map.get(body, "EnforcementStatus"),
      "max_24_hour_send" => Map.get(send_quota, "Max24HourSend"),
      "max_send_rate" => Map.get(send_quota, "MaxSendRate"),
      "sent_last_24_hours" => Map.get(send_quota, "SentLast24Hours")
    }
  end

  defp normalize_quota(_), do: %{}

  ## ---------------------------------------------------------------------------
  ## Identities
  ## ---------------------------------------------------------------------------

  @doc """
  Lists SES sending identities for the current source. See `list_identities/1`.
  """
  @spec list_identities() :: {:ok, [identity()]} | {:error, term()}
  def list_identities, do: list_identities(client())

  @doc """
  Lists SES sending identities as normalized `t:identity/0` maps.

  Pages through `AWS.SESv2.list_email_identities/4` (following `NextToken`) to
  collect the identity list, then fetches per-identity DKIM/verification detail
  via `AWS.SESv2.get_email_identity/3` (the list response carries the
  verification status but not DKIM tokens, which the dashboard needs to render
  DNS guidance). Returns `{:ok, identities}` or a wrapped `{:error, reason}`.
  """
  @spec list_identities(AWS.Client.t()) :: {:ok, [identity()]} | {:error, term()}
  def list_identities(%AWS.Client{} = client) do
    with {:ok, infos} <- list_identity_infos(client, nil, []) do
      infos
      |> Enum.reduce_while({:ok, []}, fn info, {:ok, acc} ->
        name = Map.get(info, "IdentityName")

        case get_identity(client, name) do
          {:ok, identity} -> {:cont, {:ok, [identity | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, identities} -> {:ok, Enum.reverse(identities)}
        error -> error
      end
    end
  end

  defp list_identity_infos(client, next_token, acc) do
    case AWS.SESv2.list_email_identities(client, next_token, nil) do
      {:ok, body, _resp} ->
        infos = Map.get(body, "EmailIdentities", []) || []
        acc = acc ++ infos

        case Map.get(body, "NextToken") do
          nil -> {:ok, acc}
          "" -> {:ok, acc}
          token -> list_identity_infos(client, token, acc)
        end

      other ->
        wrap(other, "list SES identities")
    end
  end

  @doc """
  Creates a new SES sending identity (domain or email address).

  See `create_identity/3`. Builds the client from the current source.
  """
  @spec create_identity(String.t()) :: {:ok, identity()} | {:error, term()}
  def create_identity(identity) when is_binary(identity),
    do: create_identity(identity, client())

  @doc """
  Creates a new SES sending identity, returning its normalized status.

  For domains, the returned map's `:dkim_tokens` feed `dns_records_for/1` to
  produce the DNS records the user must publish. For email addresses, SES sends
  a verification email and there are no DKIM tokens. Returns `{:ok, identity}`
  or a wrapped `{:error, reason}`.
  """
  @spec create_identity(String.t(), AWS.Client.t()) ::
          {:ok, identity()} | {:error, term()}
  def create_identity(identity, %AWS.Client{} = client) when is_binary(identity) do
    input = %{"EmailIdentity" => identity}

    case AWS.SESv2.create_email_identity(client, input) do
      {:ok, body, _resp} ->
        {:ok, normalize_created_identity(identity, body)}

      other ->
        wrap(other, "create identity #{inspect(identity)}")
    end
  end

  @doc """
  Re-queries a single identity's live verification/DKIM status from SES.

  See `recheck_identity/2`. Builds the client from the current source.
  """
  @spec recheck_identity(String.t()) :: {:ok, identity()} | {:error, term()}
  def recheck_identity(identity) when is_binary(identity),
    do: recheck_identity(identity, client())

  @doc """
  Re-queries a single identity's live verification/DKIM status from SES.

  This always hits `AWS.SESv2.get_email_identity/3` fresh (no caching) — the
  ticket's "live re-check". It re-asks SES for its own verification/DKIM
  determination rather than performing a raw DNS lookup: SES is the authority on
  whether an identity is usable for sending, and a passing DNS lookup that SES
  hasn't yet observed wouldn't let you send. (A supplementary `:inet_res`-based
  DNS resolver could confirm records resolve publicly; that's left as a
  dashboard-layer enhancement.) Returns `{:ok, identity}` or `{:error, reason}`.
  """
  @spec recheck_identity(String.t(), AWS.Client.t()) ::
          {:ok, identity()} | {:error, term()}
  def recheck_identity(identity, %AWS.Client{} = client) when is_binary(identity) do
    get_identity(client, identity)
  end

  defp get_identity(client, identity) do
    case AWS.SESv2.get_email_identity(client, identity) do
      {:ok, body, _resp} ->
        {:ok, normalize_got_identity(identity, body)}

      other ->
        wrap(other, "get identity #{inspect(identity)}")
    end
  end

  # From list_email_identities' identity_info + a get_email_identity fetch.
  defp normalize_got_identity(name, body) when is_map(body) do
    dkim = Map.get(body, "DkimAttributes", %{}) || %{}

    %{
      identity: name,
      type: identity_type(Map.get(body, "IdentityType"), name),
      verified?: !!Map.get(body, "VerifiedForSendingStatus"),
      verification_status: Map.get(body, "VerificationStatus"),
      dkim_status: Map.get(dkim, "Status"),
      dkim_tokens: Map.get(dkim, "Tokens", []) || [],
      dkim_signing_hosted_zone: Map.get(dkim, "SigningHostedZone"),
      sending_enabled?: Map.get(body, "VerifiedForSendingStatus")
    }
  end

  defp normalize_created_identity(name, body) when is_map(body) do
    dkim = Map.get(body, "DkimAttributes", %{}) || %{}

    %{
      identity: name,
      type: identity_type(Map.get(body, "IdentityType"), name),
      verified?: !!Map.get(body, "VerifiedForSendingStatus"),
      verification_status: nil,
      dkim_status: Map.get(dkim, "Status"),
      dkim_tokens: Map.get(dkim, "Tokens", []) || [],
      dkim_signing_hosted_zone: Map.get(dkim, "SigningHostedZone"),
      sending_enabled?: Map.get(body, "VerifiedForSendingStatus")
    }
  end

  # IdentityType is "EMAIL_ADDRESS" | "DOMAIN" | "MANAGED_DOMAIN" from SES; fall
  # back to sniffing the name for an "@" when absent.
  defp identity_type("EMAIL_ADDRESS", _name), do: :email
  defp identity_type("DOMAIN", _name), do: :domain
  defp identity_type("MANAGED_DOMAIN", _name), do: :domain

  defp identity_type(_other, name) do
    if String.contains?(name, "@"), do: :email, else: :domain
  end

  ## ---------------------------------------------------------------------------
  ## DNS record guidance (pure)
  ## ---------------------------------------------------------------------------

  @doc """
  Maps a normalized identity into the DNS records the user must publish.

  Pure function — no network calls. For a **domain** identity it returns:

    * one CNAME per DKIM token: `<token>._domainkey.<domain>` →
      `<token>.<signing_hosted_zone>` (the SES Easy DKIM pattern; the hosted
      zone comes from the identity's `:dkim_signing_hosted_zone`, defaulting to
      `#{@default_dkim_hosted_zone}` when absent),
    * an SPF `TXT` record on the domain
      (`"v=spf1 include:amazonses.com ~all"`),
    * a starter DMARC `TXT` record at `_dmarc.<domain>`.

  For an **email address** identity there are no DNS records (SES verifies via a
  confirmation email), so an empty list is returned. Each record is a
  `t:dns_record/0` map the dashboard can render as a table row.
  """
  @spec dns_records_for(identity()) :: [dns_record()]
  def dns_records_for(%{type: :email}), do: []

  def dns_records_for(%{type: :domain, identity: domain} = identity) do
    tokens = Map.get(identity, :dkim_tokens, []) || []
    hosted_zone = Map.get(identity, :dkim_signing_hosted_zone) || @default_dkim_hosted_zone

    dkim_records =
      Enum.map(tokens, fn token ->
        %{
          type: :cname,
          name: "#{token}._domainkey.#{domain}",
          value: "#{token}.#{hosted_zone}",
          purpose: :dkim
        }
      end)

    dkim_records ++
      [
        %{
          type: :txt,
          name: domain,
          value: "v=spf1 include:amazonses.com ~all",
          purpose: :spf
        },
        %{
          type: :txt,
          name: "_dmarc.#{domain}",
          value: "v=DMARC1; p=none;",
          purpose: :dmarc
        }
      ]
  end

  ## ---------------------------------------------------------------------------
  ## Response helpers
  ## ---------------------------------------------------------------------------

  # SNS CreateTopic response, XML-decoded to a nested map:
  #   %{"CreateTopicResponse" => %{"CreateTopicResult" => %{"TopicArn" => arn}}}
  defp extract_topic_arn(body) when is_map(body) do
    get_in_any(body, ["CreateTopicResponse", "CreateTopicResult", "TopicArn"]) ||
      get_in_any(body, ["TopicArn"])
  end

  defp extract_topic_arn(_), do: nil

  defp extract_subscription_arn(body) when is_map(body) do
    get_in_any(body, ["SubscribeResponse", "SubscribeResult", "SubscriptionArn"]) ||
      get_in_any(body, ["SubscriptionArn"])
  end

  defp extract_subscription_arn(_), do: nil

  # Walks a nested map by a list of string keys, returning nil on any miss.
  defp get_in_any(map, keys) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case acc do
        %{} = m ->
          case Map.get(m, key) do
            nil -> {:halt, nil}
            value -> {:cont, value}
          end

        _ ->
          {:halt, nil}
      end
    end)
  end

  # Heuristics over an error response body to detect idempotent "already exists"
  # / "not found" cases across SESv2 (JSON) and SNS (XML) shapes.
  defp already_exists?(%{body: body}) when is_binary(body) do
    String.contains?(body, "AlreadyExists") or
      String.contains?(body, "already exists") or
      String.contains?(body, "Duplicate")
  end

  defp already_exists?(_), do: false

  defp not_found?(%{body: body}) when is_binary(body) do
    String.contains?(body, "NotFound") or String.contains?(body, "does not exist")
  end

  defp not_found?(_), do: false

  # Wraps an AWS error tuple into an actionable, human-readable {:error, msg}
  # without discarding the underlying detail.
  defp wrap({:error, {:unexpected_response, %{status_code: status, body: body}}}, action) do
    detail = summarize_aws_error(status, body)

    Logger.warning("SquatchMail.SES failed to #{action}: #{detail}")
    {:error, "Failed to #{action}: #{detail}"}
  end

  defp wrap({:error, reason}, action) do
    Logger.warning("SquatchMail.SES failed to #{action}: #{inspect(reason)}")
    {:error, "Failed to #{action}: #{describe_transport_error(reason)}"}
  end

  defp summarize_aws_error(status, body) when is_binary(body) do
    hint = auth_hint(status, body)
    trimmed = body |> String.slice(0, 500)
    "HTTP #{status}#{hint} — #{trimmed}"
  end

  defp summarize_aws_error(status, _body), do: "HTTP #{status}"

  defp auth_hint(status, body) when status in [401, 403] do
    cond do
      String.contains?(body, "SignatureDoesNotMatch") ->
        " (invalid AWS secret access key)"

      String.contains?(body, "InvalidClientTokenId") ->
        " (invalid AWS access key id)"

      String.contains?(body, "ExpiredToken") ->
        " (expired session token)"

      true ->
        " (authorization failed — check the source's AWS credentials and IAM permissions)"
    end
  end

  defp auth_hint(_status, _body), do: ""

  defp describe_transport_error(:timeout), do: "request timed out"
  defp describe_transport_error(:closed), do: "connection closed"

  defp describe_transport_error(%{reason: reason}),
    do: "connection error (#{inspect(reason)})"

  defp describe_transport_error(reason), do: inspect(reason)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
