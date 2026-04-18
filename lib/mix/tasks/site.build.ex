defmodule Mix.Tasks.Site.Build do
  @shortdoc "Build the public website (ExDoc + Hugo) into site/public/"

  @moduledoc """
  Builds the public website end-to-end.

      mix site.build

  Steps:

    1. `mix docs` — generates ExDoc HTML under `doc/`.
    2. Copies `doc/` to `site/static/reference/` so Hugo picks it up.
    3. Runs `hugo --minify` under `site/`, producing `site/public/`.

  Mirrors what `.github/workflows/pages.yml` runs in CI.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("docs", [])
    sync_reference()
    hugo(["--minify" | args])
  end

  defp sync_reference do
    dest = Path.join(["site", "static", "reference"])
    File.rm_rf!(dest)
    File.mkdir_p!(Path.dirname(dest))
    File.cp_r!("doc", dest)
    Mix.shell().info("==> mounted doc/ at site/static/reference/")
  end

  defp hugo(args) do
    case System.cmd("hugo", args, cd: "site", into: IO.stream()) do
      {_, 0} -> :ok
      {_, code} -> Mix.raise("hugo exited with status #{code}")
    end
  end
end
