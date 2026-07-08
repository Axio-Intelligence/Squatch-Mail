defmodule SquatchMail.EmailRecipient do
  @moduledoc """
  A normalized recipient of an email (a to/cc/bcc address).

  Recipients are stored in their own table so that addresses can be searched and
  indexed independently of the parent email.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SquatchMail.Email

  @schema_prefix "squatch_mail"
  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  @kinds ~w(to cc bcc)

  @type t :: %__MODULE__{}

  schema "email_recipients" do
    field :kind, :string
    field :address, :string
    field :name, :string

    belongs_to :email, Email

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns the list of valid recipient kinds.
  """
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  Builds a changeset for a recipient.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(recipient, attrs) do
    recipient
    |> cast(attrs, [:email_id, :kind, :address, :name])
    |> validate_required([:kind, :address])
    |> validate_inclusion(:kind, @kinds)
    |> foreign_key_constraint(:email_id)
  end
end
