defmodule Mix.Tasks.Site.Server do
  @shortdoc "Run the Hugo dev server for local preview"

  @moduledoc """
  Serves the site locally with Hugo's live-reload dev server.

      mix site.server        # http://localhost:1313/
      mix site.server -p 4321

  Reuses `doc/` if it already exists; run `mix docs` first (or pass
  `--refresh-docs`) to regenerate ExDoc. Hugo watches `site/content/`,
  `site/layouts/`, and `site/static/` — edits live-reload. ExDoc
  output does NOT live-reload; rerun `mix docs` to refresh
  `/reference/`.

  Any extra args are forwarded to `hugo server`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {refresh, hugo_args} = Enum.split_with(args, &(&1 == "--refresh-docs"))
    ensure_docs(refresh != [])
    sync_reference()
    hugo(["server" | hugo_args])
  end

  defp ensure_docs(true), do: Mix.Task.run("docs", [])

  defp ensure_docs(false) do
    if File.exists?("doc/index.html") do
      Mix.shell().info("==> reusing existing doc/ (pass --refresh-docs to rebuild)")
    else
      Mix.Task.run("docs", [])
    end
  end

  defp sync_reference do
    dest = Path.join(["site", "static", "reference"])
    File.rm_rf!(dest)
    File.mkdir_p!(Path.dirname(dest))
    File.cp_r!("doc", dest)
  end

  defp hugo(args) do
    case System.cmd("hugo", args, cd: "site", into: IO.stream()) do
      {_, 0} -> :ok
      {_, code} -> Mix.raise("hugo exited with status #{code}")
    end
  end
end
