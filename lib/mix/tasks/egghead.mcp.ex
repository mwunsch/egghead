defmodule Mix.Tasks.Egghead.Mcp do
  @moduledoc """
  Start the MCP stdio server.

  Reads JSON-RPC messages from stdin, writes responses to stdout.
  Used by editor integrations (Claude Code, etc.) via `.mcp.json`.

      mix egghead.mcp
  """

  use Mix.Task

  @shortdoc "Start the MCP stdio server"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [help: :boolean, config: :string],
        aliases: [h: :help]
      )

    if opts[:config], do: System.put_env("EGGHEAD_CONFIG", Path.expand(opts[:config]))

    if opts[:help] do
      IO.puts("Usage: egghead mcp [--config PATH] [--help]")
    else
      Application.put_env(:egghead, :start_web, false)
      Application.put_env(:egghead, :log_mode, :silent)
      Mix.Task.run("app.start")

      Egghead.MCP.Server.loop()
    end
  end
end
