defmodule SquatchMail.Email do
  @moduledoc """
  A captured or sent email and its lifecycle status.

  Each email carries a non-enumerable `public_id` used in dashboard URLs, an
  optional SES `message_id` (the correlation key for downstream events), and
  denormalized recipient/attachment metadata. Bodies are stored inline; large
  MIME payloads are out of scope for this schema.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SquatchMail.{EmailAttachment, EmailEvent, EmailRecipient, PublicId}

  @schema_prefix "squatch_mail"
  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  @statuses ~w(captured sent delivered opened clicked bounced complained rejected delayed failed suppressed)

  @type t :: %__MODULE__{}

  schema "emails" do
    field :public_id, :string
    field :message_id, :string
    field :status, :string, default: "captured"
    field :from_email, :string
    field :from_name, :string
    field :subject, :string
    field :html_body, :string
    field :text_body, :string
    field :headers, :map, default: %{}
    field :provider_options, :map, default: %{}
    field :tags, :map, default: %{}
    field :mailer, :string
    field :adapter, :string
    field :error, :string
    field :sent_at, :utc_datetime_usec
    field :has_attachments, :boolean, default: false
    field :attachments_count, :integer, default: 0

    has_many :recipients, EmailRecipient
    has_many :attachments, EmailAttachment
    has_many :events, EmailEvent

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns the list of valid email statuses.
  """
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @castable ~w(public_id message_id status from_email from_name subject html_body
               text_body headers provider_options tags mailer adapter error
               sent_at has_attachments attachments_count)a

  @doc """
  Builds a changeset for an email. A `public_id` is generated automatically when
  one is not supplied.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(email, attrs) do
    email
    |> cast(attrs, @castable)
    |> maybe_put_public_id()
    |> validate_required([:public_id, :status, :from_email])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:public_id)
    |> unique_constraint(:message_id)
  end

  defp maybe_put_public_id(changeset) do
    case get_field(changeset, :public_id) do
      nil -> put_change(changeset, :public_id, PublicId.generate("em"))
      _ -> changeset
    end
  end
end
