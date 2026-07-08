defmodule SquatchMail.Source do
  @moduledoc """
  The (single-row) SES connection configuration.

  Holds the AWS region, configuration set, SNS topic, per-source webhook token,
  credentials, cached quota, and retention/tracking preferences. In the
  embeddable library there is exactly one source row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SquatchMail.PublicId

  @schema_prefix "squatch_mail"
  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  @credentials_modes ~w(ambient static)

  @type t :: %__MODULE__{}

  schema "sources" do
    field :region, :string, default: "us-east-1"
    field :configuration_set, :string
    field :sns_topic_arn, :string
    field :webhook_token, :string
    field :credentials_mode, :string, default: "ambient"
    field :access_key_id, :string
    # TODO: encrypt at rest
    field :secret_access_key, :string
    field :quota, :map
    field :quota_checked_at, :utc_datetime_usec
    field :retention_days, :integer, default: 90
    field :tracking_enabled, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns the list of valid credentials modes.
  """
  @spec credentials_modes() :: [String.t()]
  def credentials_modes, do: @credentials_modes

  @castable ~w(region configuration_set sns_topic_arn webhook_token
               credentials_mode access_key_id secret_access_key quota
               quota_checked_at retention_days tracking_enabled)a

  @doc """
  Builds a changeset for the source. A `webhook_token` is generated when absent.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(source, attrs) do
    source
    |> cast(attrs, @castable)
    |> maybe_put_webhook_token()
    |> validate_required([:region, :webhook_token, :credentials_mode, :retention_days])
    |> validate_inclusion(:credentials_mode, @credentials_modes)
    |> validate_number(:retention_days, greater_than: 0)
    |> unique_constraint(:webhook_token)
  end

  defp maybe_put_webhook_token(changeset) do
    case get_field(changeset, :webhook_token) do
      nil -> put_change(changeset, :webhook_token, PublicId.random_base62(32))
      _ -> changeset
    end
  end
end
