defmodule SquatchMail.EmailAttachment do
  @moduledoc """
  Metadata about an attachment on an email.

  Only the metadata (filename, content type, size, disposition) is stored; the
  attachment content itself is not persisted.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SquatchMail.Email

  @schema_prefix "squatch_mail"
  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  @type t :: %__MODULE__{}

  schema "email_attachments" do
    field :filename, :string
    field :content_type, :string
    field :size, :integer
    field :disposition, :string

    belongs_to :email, Email

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds a changeset for an attachment.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:email_id, :filename, :content_type, :size, :disposition])
    |> validate_required([:filename])
    |> foreign_key_constraint(:email_id)
  end
end
