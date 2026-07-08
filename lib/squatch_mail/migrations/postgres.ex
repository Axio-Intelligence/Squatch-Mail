defmodule SquatchMail.Migrations.Postgres do
  @moduledoc false

  # Postgres migrator, modeled on `Oban.Migrations.Postgres`.
  #
  # Applies per-version migration modules (`V01`, `V02`, ...) in order, tracking
  # the currently-applied version as a Postgres `COMMENT` on the `emails` table.
  # The `emails` table is chosen as the stable version marker (as Oban comments
  # `oban_jobs`) because it exists from V01 onward and is never dropped, so the
  # comment survives across every future version.

  use Ecto.Migration

  @initial_version 1
  @current_version 2

  # The table whose COMMENT stores the applied version.
  @version_table "emails"

  @doc false
  def up(opts) when is_list(opts) do
    opts = with_defaults(opts, @current_version)
    initial = do_migrated_version(opts)

    cond do
      initial == 0 ->
        change(@initial_version..opts.version//1, :up, opts)

      initial < opts.version ->
        change((initial + 1)..opts.version//1, :up, opts)

      true ->
        :ok
    end
  end

  @doc false
  def down(opts) when is_list(opts) do
    opts = with_defaults(opts, @initial_version - 1)
    initial = max(do_migrated_version(opts), @initial_version)

    if initial >= opts.version + 1 do
      change(initial..(opts.version + 1)//-1, :down, opts)
    end

    :ok
  end

  @doc false
  def migrated_version(opts) when is_list(opts) do
    opts
    |> with_defaults(@current_version)
    |> do_migrated_version()
  end

  defp do_migrated_version(opts) when is_map(opts) do
    repo = Map.get_lazy(opts, :repo, fn -> repo() end)
    escaped_prefix = Map.fetch!(opts, :escaped_prefix)

    query = """
    SELECT pg_catalog.obj_description(pc.oid, 'pg_class')
    FROM pg_catalog.pg_class pc
    JOIN pg_catalog.pg_namespace pn ON pn.oid = pc.relnamespace
    WHERE pc.relname = '#{@version_table}'
    AND pn.nspname = '#{escaped_prefix}'
    """

    case repo.query(query, [], log: false) do
      {:ok, %{rows: [[version]]}} when is_binary(version) -> String.to_integer(version)
      _ -> 0
    end
  end

  defp change(range, direction, opts) do
    for index <- range do
      pad = String.pad_leading(to_string(index), 2, "0")
      module = Module.concat(__MODULE__, "V#{pad}")
      apply(module, direction, [opts])
    end

    case direction do
      :up -> record_version(opts, Enum.max(range))
      :down -> record_version(opts, Enum.min(range) - 1)
    end
  end

  defp record_version(_opts, 0), do: :ok

  defp record_version(%{quoted_prefix: quoted_prefix}, version) do
    execute("COMMENT ON TABLE #{quoted_prefix}.#{@version_table} IS '#{version}'")
  end

  defp with_defaults(opts, version) do
    opts = Map.new(opts)
    prefix = Map.get(opts, :prefix, SquatchMail.Config.prefix())

    opts
    |> Map.put(:prefix, prefix)
    |> Map.put(:version, Map.get(opts, :version, version))
    |> Map.put(:escaped_prefix, String.replace(prefix, "'", "\\'"))
    |> Map.put(:quoted_prefix, inspect(prefix))
    |> Map.put_new(:create_schema, prefix != "public")
  end
end
