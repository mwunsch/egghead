defmodule Egghead.Application do
  @moduledoc """
  OTP Application for Egghead.

  All runtime configuration is loaded here in `apply_config/0`.
  No runtime.exs. Sources in precedence order:

  1. Environment variables (EGGHEAD_RECORDS, PORT, etc.)
  2. Config file (~/.config/egghead/config.yml)
  3. Compile-time defaults (config/config.exs)

  In release mode (Burrito binary), `configure_for_command/1` parses
  argv BEFORE the supervision tree to determine what to start:

  | Command | Record store | Web | Log mode |
  |---------|-------------|-----|----------|
  | (none) / tui | yes | no | :file |
  | serve | yes | yes | :console |
  | mcp | yes | no | :silent |
  | agent list, llm models, doctor, init | yes | no | :silent |
  | --help, --version, config, llm list, logs | no | no | :silent |
  """

  use Application

  # Commands that need the record store + agent layer running
  @app_commands ~w(serve mcp tui init doctor rooms)
  @app_subcommands %{
    "agents" => ~w(list new),
    "llm" => ~w(test models),
    # tools always needs the app: querying agents + MCP client state
    "tools" => ~w(list show add remove who mcp)
  }

  @impl true
  def start(_type, _args) do
    if release_mode?() do
      argv = burrito_args()
      configure_for_command(argv)
    end

    apply_config()
    configure_logging()
    configure_distribution()

    children =
      cond do
        # Connected to a remote server — only start PubSub for cluster fan-out
        Egghead.Node.connected?() ->
          [
            {Phoenix.PubSub, name: Egghead.PubSub},
            Egghead.TUI.MarkdownCache
          ]

        # Standalone mode — start the full supervision tree
        Application.get_env(:egghead, :start_record_store, true) ->
          records_dir =
            Application.get_env(:egghead, :records_dir, Path.expand("~/.egghead"))

          skills_dir =
            Application.get_env(:egghead, :skills_dir, Path.expand("~/.agents/skills"))

          db_path = Path.join(records_dir, ".egghead/index.db")

          [
            {Phoenix.PubSub, name: Egghead.PubSub},
            {Task.Supervisor, name: Egghead.Tool.TaskSupervisor},
            {Egghead.RecordSupervisor,
             records_dir: records_dir, skills_dir: skills_dir, db_path: db_path},
            Egghead.MCP.Client.Registry,
            Egghead.MCP.Client.Supervisor,
            {Egghead.Agent.LayerSupervisor, records_dir: records_dir},
            {Registry, keys: :unique, name: Egghead.Doc.Registry},
            {Egghead.Doc.Supervisor, []},
            Egghead.TUI.MarkdownCache
          ] ++ web_children()

        # Commands that don't need the app (--help, config, etc.)
        true ->
          []
      end

    opts = [strategy: :one_for_one, name: Egghead.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Post-startup setup only when running our own supervision tree
    if not Egghead.Node.connected?() and
         Application.get_env(:egghead, :start_record_store, true) do
      Egghead.Agent.Supervisor.sync_agents()
      start_configured_mcp_servers()

      # Always create a dated room as fallback
      fallback_id =
        "chat-#{Date.to_iso8601(Date.utc_today())}-#{:erlang.unique_integer([:positive])}"

      Egghead.create_room_local(id: fallback_id, default: true)

      # If config specifies a default_room, rehydrate or create it and
      # promote it to the default. The fallback room stays alive but
      # is no longer the default.
      with %{default_room: name} when is_binary(name) and name != "" <-
             Application.get_env(:egghead, :config),
           {:ok, room_id} <- ensure_room(name) do
        :persistent_term.put(:egghead_default_room, room_id)
      end
    end

    if release_mode?() do
      Task.start(fn ->
        Egghead.CLI.main(burrito_args())
        System.halt(0)
      end)
    end

    result
  end

  # --- Command mode detection (release only) ---

  defp configure_for_command(argv) do
    # Handle --config before anything reads the config file
    case Enum.find_index(argv, &(&1 == "--config")) do
      nil ->
        :ok

      idx ->
        if val = Enum.at(argv, idx + 1), do: System.put_env("EGGHEAD_CONFIG", Path.expand(val))
    end

    # Find the command (first non-flag arg)
    command =
      argv
      |> Enum.reject(&String.starts_with?(&1, "-"))
      |> List.first()

    subcommand =
      argv
      |> Enum.reject(&String.starts_with?(&1, "-"))
      |> Enum.at(1)

    needs_app = needs_app?(command, subcommand)

    # Set flags BEFORE apply_config and supervision tree
    unless needs_app do
      Application.put_env(:egghead, :start_record_store, false)
    end

    case command do
      "serve" ->
        Application.put_env(:egghead, :log_mode, :console)

      nil ->
        # Default = TUI
        Application.put_env(:egghead, :start_web, false)
        Application.put_env(:egghead, :log_mode, :file)

      "tui" ->
        Application.put_env(:egghead, :start_web, false)
        Application.put_env(:egghead, :log_mode, :file)

      _ ->
        Application.put_env(:egghead, :start_web, false)
        Application.put_env(:egghead, :log_mode, :silent)
    end
  end

  # default = TUI
  defp needs_app?(nil, _), do: true
  defp needs_app?(cmd, _) when cmd in @app_commands, do: true

  defp needs_app?(cmd, sub) do
    case Map.get(@app_subcommands, cmd) do
      # config, logs, help, llm list, llm remove
      nil -> false
      subs -> sub in subs
    end
  end

  # --- Config loading (single source of truth) ---

  defp apply_config do
    case Egghead.Config.load() do
      {:ok, config} ->
        Application.put_env(:egghead, :config, config)
        Application.put_env(:egghead, :records_dir, Egghead.Config.records_dir(config))
        Application.put_env(:egghead, :skills_dir, Egghead.Config.skills_dir(config))
        Application.put_env(:egghead, :mcp_servers, config.mcp_servers)

        if config.server do
          Application.put_env(:egghead, :server, config.server)
        end

        bind =
          case config.web.bind do
            "0.0.0.0" -> {0, 0, 0, 0}
            _ -> {127, 0, 0, 1}
          end

        current = Application.get_env(:egghead, Egghead.Web.Endpoint, [])

        secret_overrides =
          case System.get_env("SECRET_KEY_BASE") do
            nil ->
              if bind == {0, 0, 0, 0} do
                IO.warn("""
                WARNING: Binding to 0.0.0.0 without SECRET_KEY_BASE set.
                Set SECRET_KEY_BASE for any network-exposed deployment:

                    export SECRET_KEY_BASE=$(openssl rand -base64 48)
                """)
              end

              []

            key ->
              [secret_key_base: key]
          end

        endpoint_config =
          Keyword.merge(
            current,
            [
              {:url, [host: config.web.host, port: config.web.port]},
              {:http, [ip: bind, port: config.web.port]}
            ] ++ secret_overrides
          )

        Application.put_env(:egghead, Egghead.Web.Endpoint, endpoint_config)

      {:error, _} ->
        Application.put_env(:egghead, :records_dir, Path.expand("~/.egghead"))

        current = Application.get_env(:egghead, Egghead.Web.Endpoint, [])

        endpoint_config =
          Keyword.merge(current,
            url: [host: "localhost", port: 4000],
            http: [ip: {127, 0, 0, 1}, port: 4000]
          )

        Application.put_env(:egghead, Egghead.Web.Endpoint, endpoint_config)
    end

    # Environment variable overrides
    if dir = System.get_env("EGGHEAD_RECORDS") do
      Application.put_env(:egghead, :records_dir, Path.expand(dir))
    end

    if System.get_env("EGGHEAD_WEB") == "false" do
      Application.put_env(:egghead, :start_web, false)
    end

    if port_str = System.get_env("PORT") do
      port = String.to_integer(port_str)
      current = Application.get_env(:egghead, Egghead.Web.Endpoint, [])
      http = Keyword.get(current, :http, [])

      Application.put_env(
        :egghead,
        Egghead.Web.Endpoint,
        Keyword.put(current, :http, Keyword.put(http, :port, port))
      )
    end

    if host = System.get_env("EGGHEAD_HOST") do
      current = Application.get_env(:egghead, Egghead.Web.Endpoint, [])

      Application.put_env(
        :egghead,
        Egghead.Web.Endpoint,
        Keyword.put(current, :url, host: host)
      )
    end

    if System.get_env("EGGHEAD_BIND") == "0.0.0.0" do
      current = Application.get_env(:egghead, Egghead.Web.Endpoint, [])
      http = Keyword.get(current, :http, [])

      Application.put_env(
        :egghead,
        Egghead.Web.Endpoint,
        Keyword.put(current, :http, Keyword.put(http, :ip, {0, 0, 0, 0}))
      )
    end
  end

  # --- MCP client startup ---

  defp start_configured_mcp_servers do
    servers = Application.get_env(:egghead, :mcp_servers, [])

    Enum.each(servers, fn server ->
      case Egghead.MCP.Client.Supervisor.start_server(server) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          require Logger
          Logger.warning("MCP server #{inspect(server.name)} failed to start: #{inspect(reason)}")
      end
    end)
  end

  # --- Erlang distribution ---

  defp configure_distribution do
    # Only relevant for processes that start the full app
    unless Application.get_env(:egghead, :start_record_store, true) do
      :ok
    else
      # Try to connect to an already-running server.
      # If one exists, we become a client. If not, we start as the
      # server and broadcast our presence via the connection file.
      case Egghead.Node.maybe_connect() do
        :connected ->
          :ok

        :standalone ->
          Egghead.Node.start_server()
      end
    end
  end

  # --- Logging ---

  defp configure_logging do
    case Application.get_env(:egghead, :log_mode, :console) do
      :file -> redirect_to_file()
      :silent -> redirect_to_file()
      :console -> :ok
    end
  end

  defp redirect_to_file do
    log_path = Egghead.Config.log_path()
    log_dir = Path.dirname(log_path)
    File.mkdir_p!(log_dir)

    for id <- :logger.get_handler_ids() do
      :logger.remove_handler(id)
    end

    :logger.add_handler(:egghead_file, :logger_std_h, %{
      config: %{file: String.to_charlist(log_path)}
    })
  end

  # --- Helpers ---

  # Ensure a room exists by name — check live, rehydrate from transcript,
  # or create fresh.
  defp ensure_room(name) do
    cond do
      Egghead.room_exists?(name) ->
        {:ok, name}

      match?({:ok, _}, Egghead.Chat.Room.from_transcript_local("chat/#{name}")) ->
        {:ok, name}

      true ->
        Egghead.create_room_local(id: name)
    end
  end

  defp web_children do
    if Application.get_env(:egghead, :start_web, true) do
      [Egghead.Web.Endpoint]
    else
      []
    end
  end

  defp release_mode? do
    Burrito.Util.running_standalone?()
  end

  defp burrito_args do
    Burrito.Util.Args.argv()
  end
end
