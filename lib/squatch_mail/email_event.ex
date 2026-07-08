defmodule SquatchMail.EmailEvent do
  @moduledoc """
  A downstream event observed for an email (delivery, open, click, bounce, etc.).

  Events are keyed to emails by SES `message_id`. An event may be recorded before
  its email is known (e.g. an out-of-order webhook), in which case `email_id` is
  `nil` until the email is recorded and the event is back-linked.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SquatchMail.Email

  @schema_prefix "squatch_mail"
  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  @type t :: %__MODULE__{}

  schema "email_events" do
    field :event_type, :string
    field :message_id, :string
    field :recipient, :string
    field :url, :string
    field :user_agent, :string
    field :ip_address, :string
    field :payload, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    belongs_to :email, Email

    timestamps(type: :utc_datetime_usec)
  end

  @castable ~w(email_id event_type message_id recipient url user_agent
               ip_address payload occurred_at)a

  @doc """
  Builds a changeset for an event. `occurred_at` defaults to now when omitted.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, @castable)
    |> put_default_occurred_at()
    |> validate_required([:event_type, :occurred_at])
    |> foreign_key_constraint(:email_id)
  end

  defp put_default_occurred_at(changeset) do
    case get_field(changeset, :occurred_at) do
      nil -> put_change(changeset, :occurred_at, DateTime.utc_now())
      _ -> changeset
    end
  end
end
