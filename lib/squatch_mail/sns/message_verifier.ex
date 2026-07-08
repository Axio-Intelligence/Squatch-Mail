defmodule SquatchMail.SNS.MessageVerifier do
  @moduledoc """
  Hand-written verification of Amazon SNS message signatures.

  SNS signs every HTTP(S) delivery (`Notification`, `SubscriptionConfirmation`,
  `UnsubscribeConfirmation`) with a private key, and publishes the matching
  X.509 certificate at a URL it includes in the message (`SigningCertURL`).
  Verifying a message means: fetch that certificate (after validating the URL
  actually points at AWS), extract its public key, rebuild the exact string
  SNS signed, and check the signature against it with `:public_key.verify/4`.

  This is intentionally dependency-free per `CLAUDE.md` - only `:public_key`,
  `:crypto`, and `Finch` (already a dep, via the shared `SquatchMail.Finch`
  pool) are used. No `ex_aws_sns`.

  ## Canonical string-to-sign

  SNS signs a newline-delimited string built from a fixed subset of the
  message's own fields, in a fixed order - not the raw JSON. The fields
  differ by message `Type`:

    * `Notification` - `Message`, `MessageId`, `Subject` (only if present),
      `Timestamp`, `TopicArn`, `Type`.
    * `SubscriptionConfirmation` / `UnsubscribeConfirmation` - `Message`,
      `MessageId`, `SubscribeURL`, `Timestamp`, `Token`, `TopicArn`, `Type`.

  Each field contributes two lines: its name, then its value (`"key\\nvalue\\n"`).
  Fields absent from the message (i.e. `Subject` when there is none) are
  skipped entirely rather than contributing an empty line - this is the
  "trailing newline gotcha" from the AJ Foster writeup: it's not about a
  newline at the very end, it's that every *present* field contributes
  its own trailing newline, and omitting a field must not leave a blank
  line in its place.

  ## Signature versions

  `SignatureVersion` `"1"` uses SHA1withRSA, `"2"` uses SHA256withRSA. Both
  are supported; verification dispatches on the message's own field.

  ## Escape hatch

  Set `config :squatch_mail, verify_sns_signatures: false` to skip
  verification entirely (tests, local dev without real SNS traffic). A
  warning is logged every time this bypass is exercised so it can't be
  silently left on in a real deployment.
  """

  require Logger
  require Record

  @public_key_header "public_key/include/public_key.hrl"
  Record.defrecordp(
    :otp_certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: @public_key_header)
  )

  Record.defrecordp(
    :otp_tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: @public_key_header)
  )

  Record.defrecordp(
    :certificate,
    :Certificate,
    Record.extract(:Certificate, from_lib: @public_key_header)
  )

  Record.defrecordp(
    :tbs_certificate,
    :TBSCertificate,
    Record.extract(:TBSCertificate, from_lib: @public_key_header)
  )

  Record.defrecordp(
    :subject_public_key_info,
    :SubjectPublicKeyInfo,
    Record.extract(:SubjectPublicKeyInfo, from_lib: @public_key_header)
  )

  @type message :: %{optional(String.t()) => String.t()}

  @cert_host_regex ~r/^sns\.[a-z0-9-]+\.amazonaws\.com(\.cn)?$/

  @notification_fields ~w(Message MessageId Subject Timestamp TopicArn Type)
  @confirmation_fields ~w(Message MessageId SubscribeURL Timestamp Token TopicArn Type)

  @signature_versions %{"1" => :sha, "2" => :sha256}

  @cert_table :squatch_mail_sns_cert_cache

  @doc """
  Verifies an SNS message's signature.

  `message` is the JSON-decoded SNS envelope (string keys, as delivered)
  containing at least `Type`, `Message`, `MessageId`, `Timestamp`,
  `TopicArn`, `SignatureVersion`, `Signature`, and `SigningCertURL`, plus
  `Subject` (Notification, optional) or `SubscribeURL`/`Token`
  (SubscriptionConfirmation/UnsubscribeConfirmation).

  Returns `:ok` or `{:error, reason}`. `reason` is an atom or string
  describing what failed (missing field, bad cert host, expired cert,
  signature mismatch, fetch failure, etc).
  """
  @spec verify(message()) :: :ok | {:error, term()}
  def verify(message) when is_map(message) do
    if verify_signatures?() do
      do_verify(message)
    else
      Logger.warning(
        "SquatchMail.SNS.MessageVerifier: signature verification is disabled " <>
          "(config :squatch_mail, verify_sns_signatures: false) - accepting " <>
          "message #{inspect(message["MessageId"])} unverified."
      )

      :ok
    end
  end

  defp verify_signatures? do
    case Application.get_env(:squatch_mail, :verify_sns_signatures, true) do
      false -> false
      _ -> true
    end
  end

  defp do_verify(message) do
    with {:ok, fields} <- fields_for_type(message["Type"]),
         :ok <- require_fields(message, fields ++ ~w(SignatureVersion Signature SigningCertURL)),
         {:ok, hash_algo} <- hash_algorithm(message["SignatureVersion"]),
         {:ok, cert_url} <- validate_cert_url(message["SigningCertURL"]),
         {:ok, signature} <- decode_signature(message["Signature"]),
         {:ok, {public_key, not_before, not_after}} <- fetch_public_key(cert_url),
         :ok <- validate_timestamp(message["Timestamp"], not_before, not_after) do
      string_to_sign = string_to_sign(message, fields)

      if :public_key.verify(string_to_sign, hash_algo, signature, public_key) do
        :ok
      else
        {:error, :signature_mismatch}
      end
    end
  end

  ## ---------------------------------------------------------------------------
  ## String-to-sign construction
  ## ---------------------------------------------------------------------------

  defp fields_for_type("Notification"), do: {:ok, @notification_fields}
  defp fields_for_type("SubscriptionConfirmation"), do: {:ok, @confirmation_fields}
  defp fields_for_type("UnsubscribeConfirmation"), do: {:ok, @confirmation_fields}
  defp fields_for_type(nil), do: {:error, :missing_type}
  defp fields_for_type(other), do: {:error, {:unsupported_type, other}}

  # `Subject` is the only optional field (Notification messages without a
  # Subject omit it) - every other field in `fields` is required.
  defp require_fields(message, fields) do
    missing =
      fields
      |> Enum.reject(&(&1 == "Subject"))
      |> Enum.reject(&Map.has_key?(message, &1))

    case missing do
      [] -> :ok
      missing -> {:error, {:missing_fields, missing}}
    end
  end

  # Builds the exact newline-delimited string SNS signed: each present field
  # contributes "Name\nValue\n". A field with no value in the message (only
  # possible for the optional `Subject`) contributes nothing - not even a
  # blank line.
  defp string_to_sign(message, fields) do
    fields
    |> Enum.flat_map(fn key ->
      case Map.fetch(message, key) do
        {:ok, value} -> [key, "\n", to_string(value), "\n"]
        :error -> []
      end
    end)
    |> IO.iodata_to_binary()
  end

  defp hash_algorithm(version) do
    case Map.fetch(@signature_versions, version) do
      {:ok, algo} -> {:ok, algo}
      :error -> {:error, {:unsupported_signature_version, version}}
    end
  end

  defp decode_signature(signature) do
    case Base.decode64(signature) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_signature_encoding}
    end
  end

  ## ---------------------------------------------------------------------------
  ## SigningCertURL validation + fetch (validated BEFORE any network call)
  ## ---------------------------------------------------------------------------

  defp validate_cert_url(nil), do: {:error, :missing_signing_cert_url}

  defp validate_cert_url(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme != "https" ->
        {:error, :signing_cert_url_not_https}

      is_nil(uri.host) or not Regex.match?(@cert_host_regex, uri.host) ->
        {:error, :signing_cert_url_bad_host}

      is_nil(uri.path) or not String.ends_with?(uri.path, ".pem") ->
        {:error, :signing_cert_url_bad_path}

      true ->
        {:ok, url}
    end
  end

  defp fetch_public_key(url) do
    case cert_cache_get(url) do
      {:ok, entry} ->
        {:ok, entry}

      :miss ->
        with {:ok, pem} <- fetch_cert_body(url),
             {:ok, entry} <- decode_cert(pem) do
          cert_cache_put(url, entry)
          {:ok, entry}
        end
    end
  end

  defp fetch_cert_body(url) do
    fetcher = Application.get_env(:squatch_mail, :sns_cert_fetcher, &default_fetch/1)

    case fetcher.(url) do
      {:ok, body} when is_binary(body) -> {:ok, body}
      {:error, reason} -> {:error, {:cert_fetch_failed, reason}}
    end
  end

  defp default_fetch(url) do
    request = Finch.build(:get, url)

    case Finch.request(request, SquatchMail.Finch) do
      {:ok, %Finch.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Finch.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_cert(pem) do
    with [pem_entry] <- :public_key.pem_decode(pem),
         {:ok, otp_cert} <- decode_otp_cert(pem_entry),
         {:ok, not_before, not_after} <- cert_validity(otp_cert),
         {:ok, public_key} <- extract_public_key(pem_entry) do
      {:ok, {public_key, not_before, not_after}}
    else
      [] -> {:error, :empty_pem}
      [_ | _] -> {:error, :multiple_pem_entries}
      {:error, _} = error -> error
    end
  end

  defp decode_otp_cert({:Certificate, der, _}) do
    {:ok, :public_key.pkix_decode_cert(der, :otp)}
  catch
    _kind, reason -> {:error, {:cert_decode_failed, reason}}
  end

  defp decode_otp_cert(_), do: {:error, :not_a_certificate}

  defp cert_validity(otp_cert) do
    tbs = otp_certificate(otp_cert, :tbsCertificate)
    {:Validity, not_before, not_after} = otp_tbs_certificate(tbs, :validity)

    with {:ok, not_before_dt} <- parse_cert_time(not_before),
         {:ok, not_after_dt} <- parse_cert_time(not_after) do
      {:ok, not_before_dt, not_after_dt}
    end
  end

  defp parse_cert_time({:utcTime, chars}) do
    case List.to_string(chars) do
      <<yy::binary-2, mm::binary-2, dd::binary-2, hh::binary-2, min::binary-2, ss::binary-2, "Z">> ->
        year_2digit = String.to_integer(yy)
        year = if year_2digit >= 50, do: 1900 + year_2digit, else: 2000 + year_2digit
        build_datetime(year, mm, dd, hh, min, ss)

      other ->
        {:error, {:bad_cert_time, other}}
    end
  end

  defp parse_cert_time({:generalTime, chars}) do
    case List.to_string(chars) do
      <<yyyy::binary-4, mm::binary-2, dd::binary-2, hh::binary-2, min::binary-2, ss::binary-2,
        "Z">> ->
        build_datetime(String.to_integer(yyyy), mm, dd, hh, min, ss)

      other ->
        {:error, {:bad_cert_time, other}}
    end
  end

  defp build_datetime(year, mm, dd, hh, min, ss) do
    with {:ok, date} <- Date.new(year, String.to_integer(mm), String.to_integer(dd)),
         {:ok, time} <-
           Time.new(String.to_integer(hh), String.to_integer(min), String.to_integer(ss)),
         {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
      {:ok, datetime}
    end
  end

  defp extract_public_key(pem_entry) do
    key =
      pem_entry
      |> :public_key.pem_entry_decode()
      |> certificate(:tbsCertificate)
      |> tbs_certificate(:subjectPublicKeyInfo)
      |> subject_public_key_info(:subjectPublicKey)

    {:ok, :public_key.der_decode(:RSAPublicKey, key)}
  catch
    _kind, reason -> {:error, {:public_key_extract_failed, reason}}
  end

  defp validate_timestamp(nil, _not_before, _not_after), do: {:error, :missing_timestamp}

  defp validate_timestamp(timestamp_str, not_before, not_after) do
    case DateTime.from_iso8601(timestamp_str) do
      {:ok, timestamp, _offset} ->
        cond do
          DateTime.before?(timestamp, not_before) ->
            {:error, :timestamp_before_cert_validity}

          DateTime.after?(timestamp, not_after) ->
            {:error, :timestamp_after_cert_validity}

          true ->
            :ok
        end

      {:error, _reason} ->
        {:error, {:invalid_timestamp, timestamp_str}}
    end
  end

  ## ---------------------------------------------------------------------------
  ## Cert cache - lazily-created public ETS table keyed by URL
  ## ---------------------------------------------------------------------------

  defp cert_cache_get(url) do
    ensure_table()

    case :ets.lookup(@cert_table, url) do
      [{^url, {_public_key, _not_before, not_after} = entry}] ->
        if DateTime.after?(DateTime.utc_now(), not_after) do
          :ets.delete(@cert_table, url)
          :miss
        else
          {:ok, entry}
        end

      [] ->
        :miss
    end
  end

  defp cert_cache_put(url, entry) do
    ensure_table()
    :ets.insert(@cert_table, {url, entry})
    :ok
  end

  defp ensure_table do
    if :ets.whereis(@cert_table) == :undefined do
      # `:public_key.pem_decode/1` etc are pure and reentrant, so a benign
      # race here (two processes both creating the table) is fine - handle
      # the ArgumentError from a concurrent creator and move on.
      try do
        :ets.new(@cert_table, [:named_table, :public, :set, read_concurrency: true])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end
end
