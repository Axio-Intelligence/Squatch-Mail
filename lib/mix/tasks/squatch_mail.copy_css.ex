defmodule Mix.Tasks.SquatchMail.CopyCss do
  @moduledoc """
  Copies the hand-written `assets/css/squatch_mail.css` into
  `priv/static/squatch_mail.css`.

  The dashboard's CSS is plain, hand-authored CSS (see the moduledoc note in
  `assets/css/squatch_mail.css` for why this project skips Tailwind/esbuild's
  CSS bundling) — there is no build step for it, only a copy, so this is a
  small dedicated task rather than a shell `cp` (which isn't portable) inside
  the `assets.build` alias in `mix.exs`.
  """
  @shortdoc "Copies squatch_mail's hand-written CSS into priv/static"

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    source = Path.join([File.cwd!(), "assets", "css", "squatch_mail.css"])
    destination = Path.join([File.cwd!(), "priv", "static", "squatch_mail.css"])

    File.mkdir_p!(Path.dirname(destination))
    File.cp!(source, destination)

    Mix.shell().info(
      "Copied #{Path.relative_to_cwd(source)} -> #{Path.relative_to_cwd(destination)}"
    )
  end
end
