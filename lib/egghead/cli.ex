defmodule Egghead.CLI do
  @moduledoc """
  CLI entry point for Egghead.

  Parses argv, configures the application, and dispatches to the
  appropriate command module. Works identically whether invoked via
  `mix egghead` (development) or a Burrito-wrapped binary (release).

  No Mix dependency — uses `Application.ensure_all_started/1`
  instead of `Mix.Task.run("app.start")`.
  """

  @commands ~w(init serve mcp llm agents skills tools rooms config doctor logs help tui eval service)

  @doc """
  Main entry point. Parses argv and dispatches to the appropriate
  command module. Called from the `mix egghead` task in development
  and from the application start callback in release mode (Burrito
  binary).
  """
  def main(argv \\ []) do
    {command, rest, global_opts} = parse(argv)

    # --config must be set before anything touches Egghead.Config
    if global_opts[:config] do
      System.put_env("EGGHEAD_CONFIG", Path.expand(global_opts[:config]))
    end

    # --server <host> is a CLI shortcut for EGGHEAD_SERVER. Set it before
    # app start so distribution discovery sees it.
    if global_opts[:server] do
      System.put_env("EGGHEAD_SERVER", global_opts[:server])
    end

    if global_opts[:no_tty] do
      Application.put_env(:egghead, :no_tty, true)
    end

    cond do
      global_opts[:help] == true and is_nil(command) and not has_non_flags?(rest) ->
        print_help()

      global_opts[:version] == true ->
        IO.puts("egghead #{version()}")

      true ->
        dispatch(command, rest, global_opts)
    end
  end

  @doc """
  Start the OTP application. Works in both Mix and release contexts.

  Config loading happens in `Application.start/2` (the single source
  of truth). This function just sets the mode flags before starting.

  ## Options
  - `:web` — start the web server (default: true)
  """
  def start_app(log_mode \\ :silent, opts \\ []) do
    Application.put_env(:egghead, :log_mode, log_mode)

    unless Keyword.get(opts, :web, true) do
      Application.put_env(:egghead, :start_web, false)
    end

    {:ok, _} = Application.ensure_all_started(:egghead)
    :ok
  end

  @doc """
  Start the app with a distribution-aware loading message.

  Shows "Connected to <node>" when a server is found, or
  "Starting Egghead..." with a spinner during standalone cold start.
  Syncs agents when running standalone.
  """
  def prepare_runtime(opts \\ []) do
    alias Egghead.CLI.Widgets

    # In release mode the app is already up by the time we get here
    # (Application.start/2 starts the tree and shows its own spinner).
    # Only wrap a spinner when we'll actually do work.
    if Application.started_applications() |> Enum.any?(&match?({:egghead, _, _}, &1)) do
      :ok
    else
      Widgets.spinner("Starting Egghead…", fn ->
        start_app(:silent, web: false)

        if not Egghead.Node.connected?() and GenServer.whereis(Egghead.RecordStore) do
          Egghead.Agent.Supervisor.sync_agents()
        end
      end)
    end

    if Egghead.Node.connected?() do
      Widgets.success("Connected to #{Egghead.Node.server_node()}")
    end

    if Keyword.get(opts, :await_mcp, false) do
      servers = Application.get_env(:egghead, :mcp_servers, [])

      if servers != [] do
        label =
          case servers do
            [one] -> "Connecting to #{one.name}…"
            _ -> "Connecting to #{length(servers)} MCP servers…"
          end

        Widgets.spinner(label, fn ->
          poll_mcp_ready(servers, 15_000)
        end)
      end
    end
  end

  @doc false
  def poll_mcp_ready(servers, deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_poll_mcp(servers, deadline)
  end

  defp do_poll_mcp(servers, deadline) do
    pending =
      Enum.filter(servers, fn s ->
        Egghead.MCP.Client.Server.status(s.name) not in [:ready, :failed]
      end)

    cond do
      pending == [] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        :timeout

      true ->
        Process.sleep(100)
        do_poll_mcp(servers, deadline)
    end
  end

  # --- Parsing ---

  defp parse(argv) do
    {global_opts, rest} = extract_global_opts(argv)

    case rest do
      [cmd | args] when cmd in @commands ->
        {String.to_atom(cmd), args, global_opts}

      args ->
        # No recognized command — default to TUI
        {nil, args, global_opts}
    end
  end

  defp extract_global_opts(argv) do
    # Only extract --config and --version. Everything else (including
    # --help/-h) stays in rest so subcommands can handle it.
    #
    # We manually pull --config from argv instead of using OptionParser
    # because OptionParser with `switches:` or `strict:` eats unknown
    # flags, and we need them to pass through to subcommands intact.

    {config, argv} = extract_flag(argv, "--config", :string)
    {server, argv} = extract_flag(argv, "--server", :string)
    version = "--version" in argv
    argv = if version, do: List.delete(argv, "--version"), else: argv
    no_tty = "--no-tty" in argv
    argv = if no_tty, do: List.delete(argv, "--no-tty"), else: argv

    opts = []
    opts = if config, do: Keyword.put(opts, :config, config), else: opts
    opts = if server, do: Keyword.put(opts, :server, server), else: opts
    opts = if version, do: Keyword.put(opts, :version, true), else: opts
    opts = if no_tty, do: Keyword.put(opts, :no_tty, true), else: opts

    # Top-level --help: only when no recognized command is present
    help = Enum.any?(argv, &(&1 in ["--help", "-h"])) and not has_command?(argv)
    opts = Keyword.put(opts, :help, help)

    {opts, argv}
  end

  # Extract a flag and its value from argv, returning {value, remaining_argv}
  defp extract_flag(argv, flag, :string) do
    case Enum.find_index(argv, &(&1 == flag)) do
      nil ->
        {nil, argv}

      idx ->
        value = Enum.at(argv, idx + 1)
        remaining = List.delete_at(argv, idx) |> List.delete_at(idx)
        {value, remaining}
    end
  end

  defp has_command?(argv) do
    Enum.any?(argv, &(&1 in @commands))
  end

  defp has_non_flags?(args), do: Enum.any?(args, &(not String.starts_with?(&1, "-")))

  # --- Dispatch ---

  # `egghead help <command>` → show that command's help
  defp dispatch(:help, [subcmd | _], _opts) when subcmd in @commands do
    dispatch(String.to_atom(subcmd), ["--help"], [])
  end

  defp dispatch(:help, [], _opts) do
    print_help()
  end

  defp dispatch(:help, [unknown | _], _opts) do
    IO.puts(:stderr, "egghead: '#{unknown}' is not an egghead command. See 'egghead --help'.")

    case suggest(unknown) do
      nil -> :ok
      suggestion -> IO.puts(:stderr, "\nDid you mean this?\n    egghead help #{suggestion}")
    end

    System.halt(1)
  end

  defp dispatch(:init, args, _opts) do
    Egghead.CLI.Init.run(args)
  end

  defp dispatch(:serve, args, _opts) do
    Egghead.CLI.Serve.run(args)
  end

  defp dispatch(:mcp, args, _opts) do
    Egghead.CLI.MCPCmd.run(args)
  end

  defp dispatch(:llm, args, _opts) do
    Egghead.CLI.LLM.run(args)
  end

  defp dispatch(:agents, args, _opts) do
    Egghead.CLI.AgentCmd.run(args)
  end

  defp dispatch(:skills, args, _opts) do
    Egghead.CLI.SkillCmd.run(args)
  end

  defp dispatch(:tools, args, _opts) do
    Egghead.CLI.ToolsCmd.run(args)
  end

  defp dispatch(:rooms, args, _opts) do
    Egghead.CLI.RoomsCmd.run(args)
  end

  defp dispatch(:config, args, _opts) do
    Egghead.CLI.ConfigCmd.run(args)
  end

  defp dispatch(:doctor, args, _opts) do
    Egghead.CLI.Doctor.run(args)
  end

  defp dispatch(:logs, args, _opts) do
    Egghead.CLI.Logs.run(args)
  end

  defp dispatch(:tui, args, _opts) do
    Egghead.CLI.TUI.run(args)
  end

  defp dispatch(:eval, args, _opts) do
    Egghead.CLI.EvalCmd.run(args)
  end

  defp dispatch(:service, args, _opts) do
    Egghead.CLI.Service.run(args)
  end

  defp dispatch(nil, [], _opts) do
    # No arguments: launch the TUI
    Egghead.CLI.TUI.run([])
  end

  defp dispatch(nil, args, _opts) do
    unknown = Enum.find(args, &(not String.starts_with?(&1, "-")))

    IO.puts(:stderr, "egghead: '#{unknown}' is not an egghead command. See 'egghead --help'.")

    case suggest(unknown) do
      nil -> :ok
      suggestion -> IO.puts(:stderr, "\nDid you mean this?\n    #{suggestion}")
    end

    System.halt(1)
  end

  # --- Helpers ---

  defp print_help do
    IO.puts("""
    USAGE
      egghead [command] [flags]

    COMMANDS
      (default)     Launch the TUI
      init          First-run setup wizard
      serve         Run web + MCP servers (headless)
      mcp           Start the MCP stdio server
      llm           Manage LLM providers
      agents        Manage agents
      skills        Manage agent skills
      tools         Inspect agent tools and MCP servers
      rooms         List open chat rooms
      eval          Run multi-agent eval tasks
      config        View/edit configuration
      service       Install/uninstall background service supervision
      doctor        Diagnose setup problems
      logs          Tail application logs

    FLAGS
      --config PATH   Override config file location
      --server HOST   Attach to an Egghead serve running on HOST
      --no-tty        Suppress spinners and ANSI styling (for pipes/CI)
      -h, --help      Show this help
      --version       Show version

    ENVIRONMENT
      EGGHEAD_CONFIG  Override the config file path
      EGGHEAD_SERVER  Attach to an Egghead serve running on this host
                      (LAN/tailnet); same as --server
      NO_COLOR        Suppress spinners and ANSI styling
                      (https://no-color.org)

    EXAMPLES
      $ egghead                       # launch the TUI
      $ egghead init                  # first-run setup
      $ egghead llm add               # add an LLM provider
      $ egghead agents new             # create a new agent
      $ egghead serve --port 8080     # run servers on port 8080

    SEE ALSO
      Run `egghead help <command>` for command-specific help.
    """)
  end

  defp suggest(input) do
    @commands
    |> Enum.map(&{&1, String.jaro_distance(input, &1)})
    |> Enum.filter(fn {_cmd, score} -> score >= 0.8 end)
    |> Enum.max_by(fn {_cmd, score} -> score end, fn -> nil end)
    |> case do
      {cmd, _score} -> cmd
      nil -> nil
    end
  end

  @version Mix.Project.config()[:version]
  defp version, do: @version
end
