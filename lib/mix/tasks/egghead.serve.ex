defmodule Mix.Tasks.Egghead.Serve do
  @moduledoc """
  Run Egghead servers without the TUI.

  Starts the web server (which includes the MCP HTTP endpoint at `/mcp`).
  Logs go to stdout. For the MCP stdio transport, use `egghead mcp`.

      mix egghead.serve
      mix egghead.serve --port 8080
  """

  use Mix.Task

  @shortdoc "Run web + MCP servers"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [port: :integer, help: :boolean, config: :string],
        aliases: [h: :help]
      )

    if opts[:config], do: System.put_env("EGGHEAD_CONFIG", Path.expand(opts[:config]))

    if opts[:help] do
      IO.puts("Usage: egghead serve [--port N] [--config PATH] [--help]")
    else
      do_serve(opts)
    end
  end

  defp do_serve(opts) do
    if port = Keyword.get(opts, :port) do
      current = Application.get_env(:egghead, Egghead.Web.Endpoint, [])
      http_config = Keyword.get(current, :http, [])
      updated_http = Keyword.put(http_config, :port, port)

      Application.put_env(
        :egghead,
        Egghead.Web.Endpoint,
        Keyword.put(current, :http, updated_http)
      )
    end

    Mix.Task.run("app.start")

    port = get_port()
    IO.puts("Egghead running on http://localhost:#{port}")
    IO.puts("MCP endpoint at http://localhost:#{port}/mcp")
    Process.sleep(:infinity)
  end

  defp get_port do
    config = Application.get_env(:egghead, Egghead.Web.Endpoint, [])
    http = Keyword.get(config, :http, [])
    Keyword.get(http, :port, 4000)
  end
end
