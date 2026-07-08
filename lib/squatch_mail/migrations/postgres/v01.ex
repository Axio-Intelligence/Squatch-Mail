defmodule SquatchMail.Migrations.Postgres.V01 do
  @moduledoc false

  use Ecto.Migration

  @doc false
  def up(%{prefix: prefix, quoted_prefix: quoted_prefix} = opts) do
    if Map.get(opts, :create_schema, true) do
      execute("CREATE SCHEMA IF NOT EXISTS #{quoted_prefix}")
    end

    create_if_not_exists table(:emails, primary_key: false, prefix: prefix) do
      add :id, :bigserial, primary_key: true
      add :public_id, :string, null: false
      add :message_id, :string
      add :status, :string, null: false, default: "captured"
      add :from_email, :string
      add :from_name, :string
      add :subject, :string
      add :html_body, :text
      add :text_body, :text
      add :headers, :map, null: false, default: %{}
      add :provider_options, :map, null: false, default: %{}
      add :tags, :map, null: false, default: %{}
      add :mailer, :string
      add :adapter, :string
      add :error, :text
      add :sent_at, :utc_datetime_usec
      add :has_attachments, :boolean, null: false, default: false
      add :attachments_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists unique_index(:emails, [:public_id], prefix: prefix)
    create_if_not_exists index(:emails, [:status, :inserted_at], prefix: prefix)
    create_if_not_exists index(:emails, [:inserted_at], prefix: prefix)
    create_if_not_exists index(:emails, [:message_id], prefix: prefix)
    create_if_not_exists index(:emails, [:from_email], prefix: prefix)

    create_if_not_exists table(:email_recipients, primary_key: false, prefix: prefix) do
      add :id, :bigserial, primary_key: true

      add :email_id,
          references(:emails, on_delete: :delete_all, prefix: prefix, type: :bigint),
          null: false

      add :kind, :string, null: false
      add :address, :string, null: false
      add :name, :string

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists index(:email_recipients, [:email_id], prefix: prefix)
    create_if_not_exists index(:email_recipients, [:address, :inserted_at], prefix: prefix)

    create_if_not_exists table(:email_attachments, primary_key: false, prefix: prefix) do
      add :id, :bigserial, primary_key: true

      add :email_id,
          references(:emails, on_delete: :delete_all, prefix: prefix, type: :bigint),
          null: false

      add :filename, :string, null: false
      add :content_type, :string
      add :size, :integer
      add :disposition, :string

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists index(:email_attachments, [:email_id], prefix: prefix)

    create_if_not_exists table(:email_events, primary_key: false, prefix: prefix) do
      add :id, :bigserial, primary_key: true

      add :email_id,
          references(:emails, on_delete: :nilify_all, prefix: prefix, type: :bigint)

      add :event_type, :string, null: false
      add :message_id, :string
      add :recipient, :string
      add :url, :string
      add :user_agent, :string
      add :ip_address, :string
      add :payload, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists index(:email_events, [:event_type], prefix: prefix)
    create_if_not_exists index(:email_events, [:message_id], prefix: prefix)
    create_if_not_exists index(:email_events, [:occurred_at], prefix: prefix)
    create_if_not_exists index(:email_events, [:email_id, :occurred_at], prefix: prefix)

    create_if_not_exists table(:suppressions, primary_key: false, prefix: prefix) do
      add :id, :bigserial, primary_key: true
      add :address, :string, null: false
      add :reason, :string, null: false
      add :event_type, :string

      add :email_id,
          references(:emails, on_delete: :nilify_all, prefix: prefix, type: :bigint)

      add :expires_at, :utc_datetime_usec
      add :notes, :text

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists unique_index(:suppressions, [:address], prefix: prefix)

    create_if_not_exists table(:webhook_logs, primary_key: false, prefix: prefix) do
      add :id, :bigserial, primary_key: true
      add :provider, :string, null: false, default: "ses"
      add :message_type, :string
      add :status, :string, null: false, default: "received"
      add :payload, :map, null: false, default: %{}
      add :error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists index(:webhook_logs, [:inserted_at], prefix: prefix)

    create_if_not_exists table(:sources, primary_key: false, prefix: prefix) do
      add :id, :bigserial, primary_key: true
      add :region, :string, null: false, default: "us-east-1"
      add :configuration_set, :string
      add :sns_topic_arn, :string
      add :webhook_token, :string, null: false
      add :credentials_mode, :string, null: false, default: "ambient"
      add :access_key_id, :text
      add :secret_access_key, :text
      add :quota, :map
      add :quota_checked_at, :utc_datetime_usec
      add :retention_days, :integer, null: false, default: 90
      add :tracking_enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists unique_index(:sources, [:webhook_token], prefix: prefix)

    :ok
  end

  @doc false
  def down(%{prefix: prefix}) do
    drop_if_exists table(:sources, prefix: prefix)
    drop_if_exists table(:webhook_logs, prefix: prefix)
    drop_if_exists table(:suppressions, prefix: prefix)
    drop_if_exists table(:email_events, prefix: prefix)
    drop_if_exists table(:email_attachments, prefix: prefix)
    drop_if_exists table(:email_recipients, prefix: prefix)
    drop_if_exists table(:emails, prefix: prefix)

    :ok
  end
end
