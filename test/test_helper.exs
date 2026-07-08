{:ok, _} = Application.ensure_all_started(:squatch_mail)

SquatchMail.Test.Repo.__adapter__().storage_up(SquatchMail.Test.Repo.config())

{:ok, _pid} = SquatchMail.Test.Repo.start_link()

Ecto.Adapters.SQL.Sandbox.mode(SquatchMail.Test.Repo, :manual)

ExUnit.start()
