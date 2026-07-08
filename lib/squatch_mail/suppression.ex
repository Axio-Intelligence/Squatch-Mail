defmodule SquatchMail.Suppression do
  @moduledoc """
  An address that should not be sent to.

  Suppressions are unique per address. Soft bounces may carry an `expires_at`
  after which the address is deliverable again; hard bounces and complaints are
  typically permanent (`expires_at` is `nil`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SquatchMail.Email

  @schema_prefix "squatch_mail"
  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  @reasons ~w(hard_bounce soft_bounce complaint manual)

  @type t :: %__MODULE__{}

  schema "suppressions" do
    field :address, :string
    field :reason, :string
    field :event_type, :string
    field :expires_at, :utc_datetime_usec
    field :notes, :string

    belongs_to :email, Email

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns the list of valid suppression reasons.
  """
  @spec reasons() :: [String.t()]
  def reasons, do: @reasons

  @doc """
  Builds a changeset for a suppression.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(suppression, attrs) do
    suppression
    |> cast(attrs, [:address, :reason, :event_type, :expires_at, :notes, :email_id])
    |> validate_required([:address, :reason])
    |> validate_inclusion(:reason, @reasons)
    |> unique_constraint(:address)
    |> foreign_key_constraint(:email_id)
  end
end
