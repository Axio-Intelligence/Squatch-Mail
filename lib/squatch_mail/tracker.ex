defmodule SquatchMail.Tracker do
  @moduledoc """
  The persistence context for SquatchMail's observability data.

  Everything the capture engine, webhook ingestion, and dashboard need to read
  and write email records, events, suppressions, and source configuration lives
  here. All database access goes through `SquatchMail.Config.repo/0` so the host
  application's repo is used, and the configured `SquatchMail.Config.prefix/0`
  schema keeps SquatchMail's tables isolated.

  ## Prefix handling

  Every SquatchMail schema declares `@schema_prefix "squatch_mail"`, which Ecto
  respects automatically for `Repo.insert/update/delete/all/get` and for queries
  built from those schemas. As a result the context does **not** pass `prefix:`
  redundantly on schema-based operations. `prefix:` is only supplied where Ecto
  can't infer it — namely the raw version-tracking SQL in the migrator (which
  passes it explicitly) — not in this module.
  """

  import Ecto.Query

  alias Ecto.Multi

  alias SquatchMail.{
    Config,
    Email,
    EmailEvent,
    Source,
    Suppression,
    WebhookLog
  }

  @typep changeset :: Ecto.Changeset.t()

  # Monotonic "engagement" ranking used to prevent status regressions. A later
  # event may only advance an email's status, never move it backwards (e.g. a
  # delivery event arriving after a click must not revert `clicked` to
  # `delivered`). Negative outcomes always win regardless of current rank.
  @status_rank %{
    "captured" => 0,
    "sent" => 1,
    "delayed" => 2,
    "delivered" => 3,
    "opened" => 4,
    "clicked" => 5,
    "bounced" => 6,
    "complained" => 7,
    "rejected" => 8,
    "failed" => 9
  }

  # Statuses that always override the current status regardless of rank.
  @terminal_negative ~w(bounced complained rejected failed)

  # Maps an SES/webhook event type to the email status it implies.
  @event_status %{
    "delivery" => "delivered",
    "open" => "opened",
    "click" => "clicked",
    "bounce" => "bounced",
    "complaint" => "complained",
    "reject" => "rejected",
    "deliverydelay" => "delayed"
  }

  ## ---------------------------------------------------------------------------
  ## Emails
  ## ---------------------------------------------------------------------------

  @doc """
  Records a captured email together with its recipients and attachments.

  `attrs` is a map of email fields plus two optional nested lists:

    * `:recipients` - list of `%{kind, address, name}` maps.
    * `:attachments` - list of `%{filename, content_type, size, disposition}` maps.

  Runs in a single transaction: the email is inserted (generating a `public_id`),
  recipients and attachments are inserted, `has_attachments`/`attachments_count`
  are derived from the attachment list, and any orphan `email_events` that
  arrived before this email was known (matched by `message_id`) are back-linked
  to the new email.

  Returns `{:ok, email}` with `:recipients` and `:attachments` preloaded, or
  `{:error, changeset}`.
  """
  @spec record_email(map()) :: {:ok, Email.t()} | {:error, changeset()}
  def record_email(attrs) do
    attrs = normalize_keys(attrs)
    recipients = Map.get(attrs, :recipients, []) || []
    attachments = Map.get(attrs, :attachments, []) || []

    email_attrs =
      attrs
      |> Map.drop([:recipients, :attachments])
      |> Map.put(:has_attachments, attachments != [])
      |> Map.put(:attachments_count, length(attachments))

    Multi.new()
    |> Multi.insert(:email, Email.changeset(%Email{}, email_attrs))
    |> Multi.merge(fn %{email: email} ->
      insert_children(email, recipients, attachments)
    end)
    |> Multi.run(:link_events, fn repo, %{email: email} ->
      {count, _} = link_orphan_events(repo, email)
      {:ok, count}
    end)
    |> repo().transaction()
    |> case do
      {:ok, %{email: email}} ->
        {:ok, repo().preload(email, [:recipients, :attachments])}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp insert_children(email, recipients, attachments) do
    recipient_multi =
      recipients
      |> Enum.with_index()
      |> Enum.reduce(Multi.new(), fn {attrs, idx}, multi ->
        changeset =
          %SquatchMail.EmailRecipient{}
          |> SquatchMail.EmailRecipient.changeset(put_email_id(attrs, email.id))

        Multi.insert(multi, {:recipient, idx}, changeset)
      end)

    attachments
    |> Enum.with_index()
    |> Enum.reduce(recipient_multi, fn {attrs, idx}, multi ->
      changeset =
        %SquatchMail.EmailAttachment{}
        |> SquatchMail.EmailAttachment.changeset(put_email_id(attrs, email.id))

      Multi.insert(multi, {:attachment, idx}, changeset)
    end)
  end

  defp put_email_id(attrs, email_id) do
    attrs
    |> normalize_keys()
    |> Map.put(:email_id, email_id)
  end

  defp link_orphan_events(_repo, %Email{message_id: nil}), do: {0, nil}

  defp link_orphan_events(repo, %Email{id: id, message_id: message_id}) do
    from(e in EmailEvent, where: e.message_id == ^message_id and is_nil(e.email_id))
    |> repo.update_all(set: [email_id: id])
  end

  @doc """
  Updates an email's status. Accepts an `%Email{}` or its integer id.
  """
  @spec update_email_status(Email.t() | integer(), String.t()) ::
          {:ok, Email.t()} | {:error, changeset()}
  def update_email_status(%Email{} = email, status) do
    email
    |> Email.changeset(%{status: status})
    |> repo().update()
  end

  def update_email_status(id, status) when is_integer(id) do
    case repo().get(Email, id) do
      nil -> {:error, :not_found}
      email -> update_email_status(email, status)
    end
  end

  @doc """
  Marks an email as sent: sets `message_id`, `sent_at`, and status `"sent"`.
  """
  @spec mark_email_sent(Email.t(), String.t(), DateTime.t()) ::
          {:ok, Email.t()} | {:error, changeset()}
  def mark_email_sent(%Email{} = email, message_id, sent_at \\ DateTime.utc_now()) do
    email
    |> Email.changeset(%{message_id: message_id, sent_at: sent_at, status: "sent"})
    |> repo().update()
  end

  ## ---------------------------------------------------------------------------
  ## Events
  ## ---------------------------------------------------------------------------

  @doc """
  Records an email event and, when possible, links it to its email and advances
  the email's status.

  The event is always inserted. If it carries a `message_id` and a matching email
  exists, the event's `email_id` is set and the email's status is advanced per
  the event-type mapping using `next_status/2` (never regressing).

  Returns `{:ok, event}` (with `email_id` set when linked) or
  `{:error, changeset}`.
  """
  @spec record_event(map()) :: {:ok, EmailEvent.t()} | {:error, changeset()}
  def record_event(attrs) do
    attrs = normalize_keys(attrs)
    message_id = Map.get(attrs, :message_id)
    email = message_id && find_email_by_message_id(message_id)

    attrs = if email, do: Map.put(attrs, :email_id, email.id), else: attrs

    Multi.new()
    |> Multi.insert(:event, EmailEvent.changeset(%EmailEvent{}, attrs))
    |> Multi.merge(fn _changes -> maybe_advance_status(email, attrs) end)
    |> repo().transaction()
    |> case do
      {:ok, %{event: event}} -> {:ok, event}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  defp maybe_advance_status(nil, _attrs), do: Multi.new()

  defp maybe_advance_status(%Email{} = email, attrs) do
    event_type = normalize_event_type(Map.get(attrs, :event_type))

    case Map.get(@event_status, event_type) do
      nil ->
        Multi.new()

      target ->
        new_status = next_status(email.status, target)

        if new_status == email.status do
          Multi.new()
        else
          Multi.update(Multi.new(), :advance, Email.changeset(email, %{status: new_status}))
        end
    end
  end

  defp normalize_event_type(nil), do: nil
  defp normalize_event_type(type) when is_binary(type), do: String.downcase(type)
  defp normalize_event_type(type), do: type |> to_string() |> String.downcase()

  @doc """
  Computes the next email status given the current status and a proposed status.

  Terminal-negative statuses (`bounced`, `complained`, `rejected`, `failed`)
  always win. Otherwise the status only advances forward per the engagement rank;
  a lower-ranked proposal is ignored. Unknown statuses are treated as rank 0.
  """
  @spec next_status(String.t(), String.t()) :: String.t()
  def next_status(current, proposed) do
    cond do
      proposed in @terminal_negative -> proposed
      current in @terminal_negative -> current
      rank(proposed) > rank(current) -> proposed
      true -> current
    end
  end

  defp rank(status), do: Map.get(@status_rank, status, 0)

  defp find_email_by_message_id(message_id) do
    repo().one(from(e in Email, where: e.message_id == ^message_id, limit: 1))
  end

  ## ---------------------------------------------------------------------------
  ## Suppressions
  ## ---------------------------------------------------------------------------

  @doc """
  Inserts or updates a suppression for an address.

  Addresses are unique. If the address is already suppressed, its `reason`,
  `event_type`, `expires_at`, and `notes` are updated (upsert) rather than
  raising a constraint error.
  """
  @spec suppress(map()) :: {:ok, Suppression.t()} | {:error, changeset()}
  def suppress(attrs) do
    attrs = normalize_keys(attrs)

    %Suppression{}
    |> Suppression.changeset(attrs)
    |> repo().insert(
      on_conflict: {:replace, [:reason, :event_type, :expires_at, :notes, :updated_at]},
      conflict_target: :address
    )
  end

  @doc """
  Deletes any suppression row(s) for the given address. Returns `{:ok, count}`.
  """
  @spec unsuppress(String.t()) :: {:ok, non_neg_integer()}
  def unsuppress(address) do
    {count, _} =
      from(s in Suppression, where: s.address == ^address)
      |> repo().delete_all()

    {:ok, count}
  end

  @doc """
  Returns `true` if a non-expired suppression exists for the address.

  A suppression is active when `expires_at IS NULL` or `expires_at > now()`.
  """
  @spec suppressed?(String.t()) :: boolean()
  def suppressed?(address) do
    now = DateTime.utc_now()

    query =
      from s in Suppression,
        where: s.address == ^address,
        where: is_nil(s.expires_at) or s.expires_at > ^now

    repo().exists?(query)
  end

  @doc """
  Lists suppressions, optionally filtered.

  Supported filters: `:reason`, `:address`, `:limit`, `:offset`.
  """
  @spec list_suppressions(map() | Keyword.t()) :: [Suppression.t()]
  def list_suppressions(filters \\ %{}) do
    filters = Map.new(filters)

    Suppression
    |> maybe_filter(:reason, Map.get(filters, :reason))
    |> maybe_filter(:address, Map.get(filters, :address))
    |> order_by([s], desc: s.inserted_at)
    |> maybe_limit(Map.get(filters, :limit))
    |> maybe_offset(Map.get(filters, :offset))
    |> repo().all()
  end

  defp maybe_filter(query, _field, nil), do: query

  defp maybe_filter(query, field, value) do
    from q in query, where: field(q, ^field) == ^value
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp maybe_offset(query, nil), do: query
  defp maybe_offset(query, offset), do: offset(query, ^offset)

  ## ---------------------------------------------------------------------------
  ## Email listing / fetching
  ## ---------------------------------------------------------------------------

  @doc """
  Lists emails with `:recipients` preloaded, optionally filtered.

  Supported filters:

    * `:status` - exact status match.
    * `:search` - case-insensitive match over subject, from_email, and
      recipient address (joins recipients only when set).
    * `:from_date` / `:to_date` - inclusive `inserted_at` bounds. Alternatively
      `:date_range` may be a `%{from: _, to: _}` map.
    * `:limit` / `:offset` - pagination (default limit 50).
  """
  @spec list_emails(map() | Keyword.t()) :: [Email.t()]
  def list_emails(filters \\ %{}) do
    filters = Map.new(filters)
    {from_date, to_date} = date_bounds(filters)
    search = normalize_search(Map.get(filters, :search))

    query =
      from e in Email,
        as: :email,
        distinct: true,
        order_by: [desc: e.inserted_at, desc: e.id]

    query
    |> filter_status(Map.get(filters, :status))
    |> filter_dates(from_date, to_date)
    |> filter_search(search)
    |> limit(^Map.get(filters, :limit, 50))
    |> maybe_offset(Map.get(filters, :offset))
    |> repo().all()
    |> repo().preload(:recipients)
  end

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: from([email: e] in query, where: e.status == ^status)

  defp filter_dates(query, nil, nil), do: query

  defp filter_dates(query, from_date, nil),
    do: from([email: e] in query, where: e.inserted_at >= ^from_date)

  defp filter_dates(query, nil, to_date),
    do: from([email: e] in query, where: e.inserted_at <= ^to_date)

  defp filter_dates(query, from_date, to_date),
    do:
      from([email: e] in query,
        where: e.inserted_at >= ^from_date and e.inserted_at <= ^to_date
      )

  defp filter_search(query, nil), do: query

  defp filter_search(query, search) do
    pattern = "%#{search}%"

    from [email: e] in query,
      left_join: r in assoc(e, :recipients),
      where:
        ilike(e.subject, ^pattern) or
          ilike(e.from_email, ^pattern) or
          ilike(r.address, ^pattern)
  end

  defp normalize_search(nil), do: nil
  defp normalize_search(""), do: nil

  defp normalize_search(search) when is_binary(search) do
    case String.trim(search) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp date_bounds(filters) do
    case Map.get(filters, :date_range) do
      %{from: from_date, to: to_date} ->
        {from_date, to_date}

      _ ->
        {Map.get(filters, :from_date), Map.get(filters, :to_date)}
    end
  end

  @doc """
  Fetches an email by its `public_id`, preloading `:recipients`, `:attachments`,
  and `:events` (events ordered by `occurred_at` ascending).

  Raises `Ecto.NoResultsError` when no email matches.
  """
  @spec get_email!(String.t()) :: Email.t()
  def get_email!(public_id) do
    events_query = from e in EmailEvent, order_by: [asc: e.occurred_at, asc: e.id]

    Email
    |> repo().get_by!(public_id: public_id)
    |> repo().preload([:recipients, :attachments, events: events_query])
  end

  ## ---------------------------------------------------------------------------
  ## Stats
  ## ---------------------------------------------------------------------------

  @doc """
  Computes send/engagement counts and rates for a date range, plus deltas versus
  the immediately-preceding equal-length period.

  Accepts `%{from: DateTime.t(), to: DateTime.t()}`. Counts are taken over
  `emails.inserted_at` within the range. Returns a map:

      %{
        current: %{sent: _, delivered: _, opened: _, clicked: _, bounced: _,
                   complained: _, total: _},
        previous: %{...same keys...},
        rates: %{delivered: float, opened: float, clicked: float,
                 bounced: float, complained: float},
        deltas: %{sent: float, delivered: float, ...}  # percent change vs previous
      }

  Rate denominators: `delivered` is over `total`; `opened`/`clicked` are over
  `delivered` (engagement of what landed); `bounced`/`complained` are over
  `total`. Deltas are percentage change of each count versus the prior period
  (`nil` when the prior count is 0 and the current is 0; `+100.0`-style growth
  when prior is 0 and current is positive is reported as `nil` to avoid dividing
  by zero — callers render "new").

  Counts are computed with two aggregate queries (one per period), each using
  `count(*) FILTER (WHERE ...)`; there is no per-row looping in Elixir.
  """
  @spec stats(%{from: DateTime.t(), to: DateTime.t()}) :: map()
  def stats(%{from: from_dt, to: to_dt}) do
    length_us = DateTime.diff(to_dt, from_dt, :microsecond)
    prev_to = from_dt
    prev_from = DateTime.add(from_dt, -length_us, :microsecond)

    current = period_counts(from_dt, to_dt)
    previous = period_counts(prev_from, prev_to)

    %{
      current: current,
      previous: previous,
      rates: rates(current),
      deltas: deltas(current, previous)
    }
  end

  defp period_counts(from_dt, to_dt) do
    query =
      from e in Email,
        where: e.inserted_at >= ^from_dt and e.inserted_at < ^to_dt,
        select: %{
          total: count(e.id),
          sent: filter(count(e.id), e.status == "sent"),
          delivered: filter(count(e.id), e.status in ["delivered", "opened", "clicked"]),
          opened: filter(count(e.id), e.status in ["opened", "clicked"]),
          clicked: filter(count(e.id), e.status == "clicked"),
          bounced: filter(count(e.id), e.status == "bounced"),
          complained: filter(count(e.id), e.status == "complained")
        }

    repo().one(query) ||
      %{total: 0, sent: 0, delivered: 0, opened: 0, clicked: 0, bounced: 0, complained: 0}
  end

  defp rates(%{total: total} = c) do
    %{
      delivered: ratio(c.delivered, total),
      opened: ratio(c.opened, c.delivered),
      clicked: ratio(c.clicked, c.delivered),
      bounced: ratio(c.bounced, total),
      complained: ratio(c.complained, total)
    }
  end

  defp ratio(_num, 0), do: 0.0
  defp ratio(num, denom), do: Float.round(num / denom * 100, 2)

  defp deltas(current, previous) do
    for key <- [:total, :sent, :delivered, :opened, :clicked, :bounced, :complained],
        into: %{} do
      {key, percent_change(Map.fetch!(current, key), Map.fetch!(previous, key))}
    end
  end

  defp percent_change(_current, 0), do: nil

  defp percent_change(current, previous),
    do: Float.round((current - previous) / previous * 100, 2)

  ## ---------------------------------------------------------------------------
  ## Retention / pruning
  ## ---------------------------------------------------------------------------

  @doc """
  Prunes data older than the source's `retention_days`.

  Deletes `emails` whose `inserted_at` is older than the cutoff (cascading to
  recipients/attachments and nilifying events via foreign keys), then deletes
  now-orphaned `email_events` (with `nil` email_id) whose `occurred_at` is older
  than the cutoff.

  Returns `%{emails: count, events: count}`.
  """
  @spec prune() :: %{emails: non_neg_integer(), events: non_neg_integer()}
  def prune do
    retention_days =
      case get_or_create_source() do
        %Source{retention_days: days} when is_integer(days) and days > 0 -> days
        _ -> 90
      end

    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)

    {emails_deleted, _} =
      from(e in Email, where: e.inserted_at < ^cutoff)
      |> repo().delete_all()

    {events_deleted, _} =
      from(ev in EmailEvent,
        where: is_nil(ev.email_id) and ev.occurred_at < ^cutoff
      )
      |> repo().delete_all()

    %{emails: emails_deleted, events: events_deleted}
  end

  ## ---------------------------------------------------------------------------
  ## Source
  ## ---------------------------------------------------------------------------

  @doc """
  Returns the single source row, inserting a default one (with a generated
  `webhook_token`) if none exists yet.
  """
  @spec get_or_create_source() :: Source.t()
  def get_or_create_source do
    case repo().one(from(s in Source, order_by: [asc: s.id], limit: 1)) do
      nil ->
        {:ok, source} =
          %Source{}
          |> Source.changeset(%{})
          |> repo().insert()

        source

      source ->
        source
    end
  end

  @doc """
  Updates the source row with the given attributes.
  """
  @spec update_source(map()) :: {:ok, Source.t()} | {:error, changeset()}
  def update_source(attrs) do
    get_or_create_source()
    |> Source.changeset(normalize_keys(attrs))
    |> repo().update()
  end

  ## ---------------------------------------------------------------------------
  ## Webhook audit log
  ## ---------------------------------------------------------------------------

  @doc """
  Records an inbound webhook audit entry.

  `attrs` follows `SquatchMail.WebhookLog`'s castable fields (`:provider`,
  `:message_type`, `:status`, `:payload`, `:error`). Callers are expected to
  log every inbound webhook payload regardless of outcome, so this always
  inserts rather than upserting.
  """
  @spec log_webhook(map()) :: {:ok, WebhookLog.t()} | {:error, changeset()}
  def log_webhook(attrs) do
    attrs = normalize_keys(attrs)

    %WebhookLog{}
    |> WebhookLog.changeset(attrs)
    |> repo().insert()
  end

  ## ---------------------------------------------------------------------------
  ## Helpers
  ## ---------------------------------------------------------------------------

  defp repo, do: Config.repo()

  # Accepts string- or atom-keyed maps and returns an atom-keyed map for the
  # keys this context understands (leaves unknown string keys behind).
  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {safe_atom(k), v}
    end)
  end

  defp safe_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> String.to_atom(string)
  end
end
