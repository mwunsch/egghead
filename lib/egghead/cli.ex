defmodule Egghead.CLI do
  @moduledoc """
  CLI entry point for Egghead.

  Parses argv, configures the application, and dispatches to the
  appropriate command module. Works identically whether invoked via
  `mix egghead` (development) or a Burrito-wrapped binary (release).

  No Mix dependency — uses `Application.ensure_all_started/1`
  instead of `Mix.Task.run("app.start")`.
  """

  @commands ~w(init serve mcp llm agent skill tools config doctor logs help tui)

  @doc """
  Main entry point. Parses argv and dispatches to the appropriate
  command module. Called from:
  - `Mix.Tasks.Egghead.run/1` (development)
  - `Application.start/2` in release mode (Burrito binary)
  """
  def main(argv \\ []) do
    {command, rest, global_opts} = parse(argv)

    # --config must be set before anything touches Egghead.Config
    if global_opts[:config] do
      System.put_env("EGGHEAD_CONFIG", Path.expand(global_opts[:config]))
    end

    cond do
      global_opts[:help] == true and is_nil(command) -> print_help()
      global_opts[:version] == true -> IO.puts("egghead #{version()}")
      true -> dispatch(command, rest, global_opts)
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
    version = "--version" in argv
    argv = if version, do: List.delete(argv, "--version"), else: argv

    opts = []
    opts = if config, do: Keyword.put(opts, :config, config), else: opts
    opts = if version, do: Keyword.put(opts, :version, true), else: opts

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

  # --- Dispatch ---

  # `egghead help <command>` → show that command's help
  defp dispatch(:help, [subcmd | _], _opts) when subcmd in @commands do
    dispatch(String.to_atom(subcmd), ["--help"], [])
  end

  defp dispatch(:help, _, _opts) do
    print_help()
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

  defp dispatch(:agent, args, _opts) do
    Egghead.CLI.AgentCmd.run(args)
  end

  defp dispatch(:skill, args, _opts) do
    Egghead.CLI.SkillCmd.run(args)
  end

  defp dispatch(:tools, args, _opts) do
    Egghead.CLI.ToolsCmd.run(args)
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

  defp dispatch(nil, _args, _opts) do
    # Default: launch the TUI
    Egghead.CLI.TUI.run([])
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
      agent         Manage agents
      config        View/edit configuration
      doctor        Diagnose setup problems
      logs          Tail application logs

    FLAGS
      --config PATH Override config file location
      -h, --help    Show this help
      --version     Show version

    ENVIRONMENT
      EGGHEAD_CONFIG  Override the config file path

    EXAMPLES
      $ egghead                       # launch the TUI
      $ egghead init                  # first-run setup
      $ egghead llm add               # add an LLM provider
      $ egghead agent new             # create a new agent
      $ egghead serve --port 8080     # run servers on port 8080

    SEE ALSO
      Run `egghead help <command>` for command-specific help.
    """)
  end

  @version Mix.Project.config()[:version]
  defp version, do: @version
end
