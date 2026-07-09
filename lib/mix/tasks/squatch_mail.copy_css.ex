defmodule Mix.Tasks.SquatchMail.CopyCss do
  @moduledoc """
  Builds `priv/static/squatch_mail.css` by concatenating
  `assets/css/fonts.css` (the base64-embedded Bebas Neue / Space Mono
  `@font-face` rules) with the hand-written `assets/css/squatch_mail.css`.

  The dashboard's CSS is plain, hand-authored CSS (see the moduledoc note in
  `assets/css/squatch_mail.css` for why this project skips Tailwind/esbuild's
  CSS bundling) — there is no build step for it beyond this concatenation,
  which exists so the giant font data-URI blobs live in their own generated
  file instead of cluttering the stylesheet humans edit, while the shipped
  bundle stays a single self-contained request.
  """
  @shortdoc "Bundles squatch_mail's fonts + hand-written CSS into priv/static"

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    fonts = Path.join([File.cwd!(), "assets", "css", "fonts.css"])
    theme = Path.join([File.cwd!(), "assets", "css", "squatch_mail.css"])
    destination = Path.join([File.cwd!(), "priv", "static", "squatch_mail.css"])

    File.mkdir_p!(Path.dirname(destination))
    File.write!(destination, File.read!(fonts) <> "\n" <> File.read!(theme))

    Mix.shell().info(
      "Bundled assets/css/{fonts,squatch_mail}.css -> #{Path.relative_to_cwd(destination)}"
    )
  end
end
