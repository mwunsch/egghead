defmodule Egghead.CLI.Serve do
  @moduledoc "Starts the web server and MCP HTTP endpoint."

  def run(args) do
    if "--help" in args or "-h" in args do
      IO.puts("""
      USAGE
        egghead serve [flags]

      DESCRIPTION
        Start the web server and MCP HTTP endpoint. The MCP endpoint is
        available at /mcp on the same port. Logs go to stdout.

        For the MCP stdio transport (editor integration), use `egghead mcp`.

      FLAGS
        --port <n>     Override the HTTP port (default: 4000)
        --config PATH  Override config file location
        -h, --help     Show this help

      EXAMPLES
        $ egghead serve
        $ egghead serve --port 8080

      SEE ALSO
        egghead mcp, egghead config, egghead doctor
      """)
    else
      do_run(args)
    end
  end

  defp do_run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [port: :integer],
        aliases: []
      )

    if port = opts[:port] do
      current = Application.get_env(:egghead, Egghead.Web.Endpoint, [])
      http_config = Keyword.get(current, :http, [])
      updated_http = Keyword.put(http_config, :port, port)

      Application.put_env(
        :egghead,
        Egghead.Web.Endpoint,
        Keyword.put(current, :http, updated_http)
      )
    end

    Egghead.CLI.start_app(:console)

    port = get_port()
    IO.puts("Egghead running on http://localhost:#{port}")
    IO.puts("MCP endpoint at http://localhost:#{port}/mcp")
    IO.puts("")
    IO.puts("Stop the server with Ctrl+C then 'a' (BEAM break menu),")
    IO.puts("or send SIGTERM: kill #{System.pid()}")
    Process.sleep(:infinity)
  end

  defp get_port do
    config = Application.get_env(:egghead, Egghead.Web.Endpoint, [])
    http = Keyword.get(config, :http, [])
    Keyword.get(http, :port, 4000)
  end
end
