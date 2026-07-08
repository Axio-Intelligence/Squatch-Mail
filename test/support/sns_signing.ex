defmodule SquatchMail.Test.SNSSigning do
  @moduledoc """
  Test helper for signing SNS message envelopes with a real, ephemeral RSA
  keypair so `SquatchMail.SNS.MessageVerifier` can be exercised end-to-end
  without ever talking to AWS.

  A single self-signed certificate is generated once per test suite run
  (`openssl` via `System.cmd/3` - simplest correct way to get a valid X.509
  cert with the exact validity window we want; hand-rolling ASN.1
  certificate construction with `:public_key.pkix_sign/2` for a test-only
  cert would be a lot of code for no extra coverage). Its private key signs
  fixtures; its PEM is served to `MessageVerifier` via the config-injectable
  `:sns_cert_fetcher` escape hatch (`config :squatch_mail, sns_cert_fetcher:
  fun`) rather than standing up a real HTTP listener - `MessageVerifier`
  doesn't care how its PEM arrives, so stubbing the fetch function directly
  is the cleanest seam and keeps these tests independent of the host's
  available webserver/port.
  """

  @cert_host "sns.us-east-1.amazonaws.com"
  @cert_path "/SimpleNotificationService-test.pem"

  @doc """
  Generates a fresh RSA keypair + self-signed certificate (valid from 1 day
  ago to 1 year from now, so any reasonable test `Timestamp` falls inside the
  window). Returns `%{private_key: :public_key.rsa_private_key(), cert_pem:
  binary(), cert_url: binary()}`.
  """
  def generate_keypair! do
    tmp_dir =
      System.tmp_dir!()
      |> Path.join("squatch_mail_sns_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    key_path = Path.join(tmp_dir, "key.pem")
    cert_path = Path.join(tmp_dir, "cert.pem")

    {_, 0} =
      System.cmd(
        "openssl",
        ~w(req -x509 -newkey rsa:2048 -keyout #{key_path} -out #{cert_path}
           -days 365 -nodes -subj /CN=#{@cert_host}),
        stderr_to_stdout: true
      )

    cert_pem = File.read!(cert_path)
    key_pem = File.read!(key_path)

    [key_entry] = :public_key.pem_decode(key_pem)
    private_key = :public_key.pem_entry_decode(key_entry)

    File.rm_rf!(tmp_dir)

    %{
      private_key: private_key,
      cert_pem: cert_pem,
      cert_url: "https://#{@cert_host}#{@cert_path}"
    }
  end

  @doc """
  Configures `:squatch_mail, :sns_cert_fetcher` to serve `cert_pem` for
  `cert_url` (and error for any other URL). Restores the previous value via
  `ExUnit.Callbacks.on_exit/1` at the end of the test.
  """
  def stub_cert_fetcher(cert_url, cert_pem) do
    previous = Application.get_env(:squatch_mail, :sns_cert_fetcher)

    fetcher = fn
      ^cert_url -> {:ok, cert_pem}
      other -> {:error, {:unexpected_url_in_test, other}}
    end

    Application.put_env(:squatch_mail, :sns_cert_fetcher, fetcher)

    ExUnit.Callbacks.on_exit(fn ->
      if previous do
        Application.put_env(:squatch_mail, :sns_cert_fetcher, previous)
      else
        Application.delete_env(:squatch_mail, :sns_cert_fetcher)
      end
    end)

    :ok
  end

  @doc """
  Returns the `cert_url` this module always signs against, so tests can
  build fixtures referencing it directly (mostly useful for negative tests
  that deliberately mismatch it).
  """
  def cert_url(%{cert_url: cert_url}), do: cert_url

  @notification_fields ~w(Message MessageId Subject Timestamp TopicArn Type)
  @confirmation_fields ~w(Message MessageId SubscribeURL Timestamp Token TopicArn Type)

  @doc """
  Signs an SNS envelope map (string keys, everything but `Signature`,
  `SignatureVersion`, and `SigningCertURL` already populated) with the given
  keypair, returning the envelope with those three fields filled in.

  `signature_version` is `"1"` (SHA1withRSA) or `"2"` (SHA256withRSA).
  """
  def sign(envelope, %{private_key: private_key, cert_url: cert_url}, signature_version \\ "2") do
    hash_algo = if signature_version == "1", do: :sha, else: :sha256
    fields = fields_for_type(envelope["Type"])
    string_to_sign = string_to_sign(envelope, fields)
    signature = :public_key.sign(string_to_sign, hash_algo, private_key) |> Base.encode64()

    envelope
    |> Map.put("SignatureVersion", signature_version)
    |> Map.put("Signature", signature)
    |> Map.put("SigningCertURL", cert_url)
  end

  defp fields_for_type("Notification"), do: @notification_fields
  defp fields_for_type("SubscriptionConfirmation"), do: @confirmation_fields
  defp fields_for_type("UnsubscribeConfirmation"), do: @confirmation_fields

  defp string_to_sign(envelope, fields) do
    fields
    |> Enum.flat_map(fn key ->
      case Map.fetch(envelope, key) do
        {:ok, value} -> [key, "\n", to_string(value), "\n"]
        :error -> []
      end
    end)
    |> IO.iodata_to_binary()
  end
end
