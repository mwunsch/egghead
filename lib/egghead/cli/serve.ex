defmodule Egghead.CLI.Serve do
  @moduledoc false

  def run(args) do
    if "--help" in args or "-h" in args do
      IO.puts("""
      USAGE
        egghead serve [flags]

      DESCRIPTION
        Start the web server (with the MCP HTTP endpoint at /mcp) and the
        IRC server. Both run in the same supervision tree on sensible
        defaults — no config required. Logs go to stdout.

        For the MCP stdio transport (editor integration), use `egghead mcp`.

      FLAGS
        --port <n>       Override the HTTP port (default: 4000)
        --irc-port <n>   Override the IRC port (default: 6667)
        --no-web         Skip starting the web / MCP-HTTP endpoint
        --no-irc         Skip starting the IRC server
        --config PATH    Override config file location
        -h, --help       Show this help

      ENVIRONMENT
        PORT, EGGHEAD_HOST, EGGHEAD_BIND, EGGHEAD_WEB=false
        EGGHEAD_IRC_PORT, EGGHEAD_IRC_BIND, EGGHEAD_IRC=false
        EGGHEAD_IRC_PASSWORD (if `irc.password: "{env:...}"` is configured)

      EXAMPLES
        $ egghead serve
        $ egghead serve --port 8080
        $ egghead serve --irc-port 6697
        $ egghead serve --no-web                 # IRC-only
        $ egghead serve --no-irc                 # web-only

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
        switches: [
          port: :integer,
          irc_port: :integer,
          no_web: :boolean,
          no_irc: :boolean
        ],
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

    # IRC port overrides have to land on the loaded Config struct because
    # the IRC supervisor reads from there at boot. CLI flag wins over env
    # var wins over config file (CLI runs after apply_config in start_app).
    if irc_port = opts[:irc_port], do: put_irc_field(:port, irc_port)

    if opts[:no_web], do: Application.put_env(:egghead, :start_web, false)
    if opts[:no_irc], do: Application.put_env(:egghead, :start_irc, false)

    Egghead.CLI.start_app(:console)

    if Egghead.Node.connected?() do
      IO.puts("Another Egghead instance is already running (#{Egghead.Node.server_node()}).")
      IO.puts("Stop it first, or run `egghead` to connect as a client.")
      System.halt(1)
    end

    port = get_port()

    if Application.get_env(:egghead, :start_web, true) do
      IO.puts("Egghead web on http://localhost:#{port}")
      IO.puts("MCP endpoint at http://localhost:#{port}/mcp")
    end

    case irc_listening_on() do
      nil -> :ok
      {host, irc_port} -> IO.puts("Egghead IRC on irc://#{host}:#{irc_port}")
    end

    if node() != :nonode@nohost do
      IO.puts("Node: #{node()}")
      print_lan_attach_hint()
    end

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

  defp irc_listening_on do
    cond do
      Application.get_env(:egghead, :start_irc, true) == false ->
        nil

      Process.whereis(Egghead.IRC.Server) == nil ->
        nil

      true ->
        cfg =
          case Application.get_env(:egghead, :config) do
            %{irc: %{} = irc} -> irc
            _ -> %{}
          end

        {Map.get(cfg, :bind, "127.0.0.1"), Map.get(cfg, :port, 6667)}
    end
  end

  defp put_irc_field(key, value) do
    case Application.get_env(:egghead, :config) do
      %Egghead.Config{} = cfg ->
        irc = Map.put(cfg.irc || %{}, key, value)
        Application.put_env(:egghead, :config, %{cfg | irc: irc})

      _ ->
        :ok
    end
  end

  # Show how a peer host should attach when this server is reachable
  # off-box. We only print the hint when `server.host` is configured —
  # that's the explicit signal that the operator wants cross-host
  # distribution. Same-host attach is zero-config and doesn't need a hint.
  defp print_lan_attach_hint do
    case Application.get_env(:egghead, :server) do
      %{host: host} when is_binary(host) and host != "" ->
        IO.puts("")
        IO.puts("To attach from another host on the same network:")
        IO.puts("  EGGHEAD_SERVER=#{host} egghead          # TUI")
        IO.puts("  EGGHEAD_SERVER=#{host} egghead mcp      # MCP stdio")
        IO.puts("Both hosts must share ~/.erlang.cookie.")

      _ ->
        :ok
    end
  end
end
