defmodule Egghead.CLI.MCPCmd do
  @moduledoc "Starts the MCP stdio server."

  def run(args) do
    if "--help" in args or "-h" in args do
      IO.puts("""
      USAGE
        egghead mcp [flags]

      DESCRIPTION
        Start the MCP stdio server. Reads JSON-RPC messages from stdin,
        writes responses to stdout. Used by editor integrations like
        Claude Code via .mcp.json.

        For the HTTP MCP endpoint, use `egghead serve` (available at /mcp).

      FLAGS
        --config PATH   Override config file location
        -h, --help      Show this help

      SEE ALSO
        egghead serve
      """)
    else
      do_run()
    end
  end

  defp do_run do
    Egghead.CLI.start_app(:silent, web: false)
    Egghead.MCP.Server.loop()
  end
end
