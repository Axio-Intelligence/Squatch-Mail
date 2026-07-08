defmodule SquatchMail.Config do
  @moduledoc """
  Reads SquatchMail's application configuration.

  The host application configures SquatchMail like any other library:

      config :squatch_mail,
        repo: MyApp.Repo,
        otp_app: :my_app,
        prefix: "squatch_mail",
        enabled: true,
        capture: [
          store_html: true,
          store_text: true,
          sample_rate: 1.0,
          max_queue: 10_000
        ]

  ## Options

    * `:repo` (required) - the `Ecto.Repo` SquatchMail uses to read and write
      its own tables. This is expected to be the host application's existing
      repo; SquatchMail keeps its tables isolated in their own Postgres
      schema (see `:prefix`).
    * `:otp_app` - the OTP application configuring SquatchMail. Used by
      future installer/asset tasks to locate the host app's directories.
    * `:prefix` - the Postgres schema all SquatchMail tables live in.
      Defaults to `"squatch_mail"`.
    * `:enabled` - whether SquatchMail's capture/ingestion machinery is
      active. Defaults to `true`. Useful for disabling SquatchMail in
      specific environments (e.g. test) without removing its configuration.
    * `:capture` - options for the telemetry capture engine
      (`SquatchMail.Capture`), a keyword list:
        * `:store_html` - whether to persist the HTML body. Defaults to
          `true`. Set to `false` to keep engagement/status data while
          dropping potentially sensitive HTML content.
        * `:store_text` - whether to persist the plain-text body. Defaults
          to `true`, same rationale as `:store_html`.
        * `:sample_rate` - the fraction (`0.0`..`1.0`) of outgoing emails the
          capture engine persists. Defaults to `1.0` (capture every send).
          Lower this for very high-volume mailers where full capture would
          be too much write load; `1.0` and `0.0` are treated as exact (no
          random sampling overhead at the extremes).
        * `:max_queue` - the maximum number of captured emails the
          `SquatchMail.Capture.Recorder` will hold pending persistence before
          it starts dropping new captures (and emitting
          `[:squatch_mail, :capture, :dropped]`) rather than let the queue
          grow unbounded under a burst. Defaults to `10_000`.
  """

  @default_prefix "squatch_mail"

  @doc """
  Returns the configured `Ecto.Repo`.

  Raises if `:repo` has not been configured.
  """
  @spec repo() :: Ecto.Repo.t()
  def repo do
    Application.get_env(:squatch_mail, :repo) ||
      raise """
      SquatchMail is missing a configured :repo.

      Please configure it in your config files:

          config :squatch_mail, repo: MyApp.Repo
      """
  end

  @doc """
  Returns the configured OTP application, if any.
  """
  @spec otp_app() :: atom() | nil
  def otp_app do
    Application.get_env(:squatch_mail, :otp_app)
  end

  @doc """
  Returns the Postgres schema SquatchMail's tables live in.

  Defaults to `#{inspect(@default_prefix)}`.
  """
  @spec prefix() :: String.t()
  def prefix do
    Application.get_env(:squatch_mail, :prefix, @default_prefix)
  end

  @doc """
  Returns whether SquatchMail is enabled.

  Defaults to `true`.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    !!Application.get_env(:squatch_mail, :enabled, true)
  end

  @default_capture [store_html: true, store_text: true, sample_rate: 1.0, max_queue: 10_000]

  @doc """
  Returns a single capture option, falling back to its default when the host
  hasn't configured `:capture` at all, or has configured it but omitted this
  particular key.
  """
  @spec capture(atom()) :: term()
  def capture(key) when is_atom(key) do
    configured = Application.get_env(:squatch_mail, :capture, [])
    Keyword.get(configured, key, Keyword.fetch!(@default_capture, key))
  end

  @doc """
  Returns whether the HTML body should be persisted for captured emails.

  Defaults to `true`.
  """
  @spec store_html?() :: boolean()
  def store_html?, do: !!capture(:store_html)

  @doc """
  Returns whether the plain-text body should be persisted for captured
  emails.

  Defaults to `true`.
  """
  @spec store_text?() :: boolean()
  def store_text?, do: !!capture(:store_text)

  @doc """
  Returns the configured sample rate for the telemetry capture engine.

  Defaults to `1.0`.
  """
  @spec sample_rate() :: float()
  def sample_rate, do: capture(:sample_rate) * 1.0

  @doc """
  Returns the maximum number of pending captures
  `SquatchMail.Capture.Recorder` will queue before dropping new ones.

  Defaults to `10_000`.
  """
  @spec max_queue() :: non_neg_integer()
  def max_queue, do: capture(:max_queue)
end
