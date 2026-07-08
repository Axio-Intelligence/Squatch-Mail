defmodule SquatchMail.DataCase do
  @moduledoc """
  Test case for tests that require access to `SquatchMail.Test.Repo`.

  Wraps each test in an `Ecto.Adapters.SQL.Sandbox` transaction so database
  changes are rolled back automatically.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias SquatchMail.Test.Repo

      import Ecto
      import Ecto.Query
      import SquatchMail.DataCase
    end
  end

  setup tags do
    SquatchMail.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(SquatchMail.Test.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
