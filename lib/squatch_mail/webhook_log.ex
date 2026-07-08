defmodule SquatchMail.WebhookLog do
  @moduledoc """
  A raw audit record of an inbound webhook payload (typically SNS/SES).

  Every inbound payload is logged with its processing status so that ingestion
  failures can be inspected and replayed.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @schema_prefix "squatch_mail"
  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  @statuses ~w(received processed ignored failed)

  @type t :: %__MODULE__{}

  schema "webhook_logs" do
    field :provider, :string, default: "ses"
    field :message_type, :string
    field :status, :string, default: "received"
    field :payload, :map, default: %{}
    field :error, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns the list of valid webhook log statuses.
  """
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  Builds a changeset for a webhook log entry.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(log, attrs) do
    log
    |> cast(attrs, [:provider, :message_type, :status, :payload, :error])
    |> validate_required([:provider, :status])
    |> validate_inclusion(:status, @statuses)
  end
end
