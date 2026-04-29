defmodule Egghead.CLI.Service do
  @moduledoc """
  `egghead service` — install/uninstall a user-scope process supervisor
  unit so `egghead serve` survives logout and restarts on failure.

  Platform branches:

  - macOS: LaunchAgent at `~/Library/LaunchAgents/computer.egghead.plist`,
    label `computer.egghead`. Loaded via `launchctl bootstrap`.
  - Linux: systemd user unit at
    `~/.config/systemd/user/egghead.service`. Enabled and started via
    `systemctl --user`.

  See `~/.egghead/design/service-supervision.md` for the design notes
  (env-ref baking, log routing, binary resolution).
  """

  alias Egghead.CLI.Widgets
  alias Egghead.Config

  @label "computer.egghead"
  @plist_filename "computer.egghead.plist"
  @unit_filename "egghead.service"

  # Embed the templates at compile time so they ship with the Burrito
  # release without needing the rel/ directory at runtime.
  @launchd_template_path Path.expand("../../../rel/service/launchd.plist.eex", __DIR__)
  @systemd_template_path Path.expand("../../../rel/service/systemd.service.eex", __DIR__)
  @external_resource @launchd_template_path
  @external_resource @systemd_template_path
  @launchd_template File.read!(@launchd_template_path)
  @systemd_template File.read!(@systemd_template_path)

  def run(args) do
    case args do
      [] -> print_help()
      ["--help" | _] -> print_help()
      ["-h" | _] -> print_help()
      ["help" | _] -> print_help()
      ["install" | rest] -> install(rest)
      ["uninstall" | rest] -> uninstall(rest)
      ["status" | rest] -> status(rest)
      ["logs" | rest] -> Egghead.CLI.Logs.run(rest)
      [unknown | _] -> unknown_subcommand(unknown)
    end
  end

  defp print_help do
    IO.puts("""
    USAGE
      egghead service <subcommand> [flags]

    DESCRIPTION
      Manage a user-scope process supervisor for `egghead serve`.
      Writes a LaunchAgent (macOS) or systemd user unit (Linux) that
      starts Egghead at login and restarts it on failure.

      Logs are routed to the standard XDG log file
      (#{Config.log_path()}), the same place `egghead logs` reads.

    SUBCOMMANDS
      install      Write the unit and load it
      uninstall    Stop, unload, and remove the unit
      status       Show platform-native service status
      logs         Tail the XDG log file (alias of `egghead logs`)

    EXAMPLES
      $ egghead service install
      $ egghead service status
      $ egghead service logs
      $ egghead service uninstall

    SEE ALSO
      egghead serve, egghead logs, egghead doctor
    """)
  end

  defp unknown_subcommand(name) do
    IO.puts(:stderr, "egghead service: '#{name}' is not a service subcommand.")
    IO.puts(:stderr, "Run `egghead service --help` for usage.")
    System.halt(1)
  end

  # --- install ---

  @doc false
  def install(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [yes: :boolean, dry_run: :boolean],
        aliases: [y: :yes]
      )

    case resolve_binary() do
      {:ok, binary, source} ->
        do_install(binary, source, opts)

      {:error, reason} ->
        Widgets.error(reason)
        System.halt(1)
    end
  end

  defp do_install(binary, source, opts) do
    config_path = Config.config_path()
    log_path = Config.log_path()
    working_dir = System.user_home!()

    if source == :dev do
      Widgets.warn(
        "Installing service pointed at a dev checkout (#{binary}). " <>
          "It will keep running this code across branch switches."
      )
    end

    env_pairs = collect_env_pairs(opts)

    case platform() do
      :macos -> install_macos(binary, config_path, log_path, working_dir, env_pairs, opts)
      :linux -> install_linux(binary, config_path, log_path, working_dir, env_pairs, opts)
      other -> halt_unsupported(other)
    end
  end

  defp install_macos(binary, config_path, log_path, working_dir, env_pairs, opts) do
    ensure_log_dir(log_path)

    plist =
      EEx.eval_string(@launchd_template,
        label: @label,
        binary: binary,
        args: ["serve"],
        working_dir: working_dir,
        config_path: config_path,
        log_path: log_path,
        env_pairs: env_pairs
      )

    plist_path = Path.join([working_dir, "Library/LaunchAgents", @plist_filename])

    if opts[:dry_run] do
      IO.puts("# Would write #{plist_path}:\n")
      IO.puts(plist)
    else
      File.mkdir_p!(Path.dirname(plist_path))
      File.write!(plist_path, plist)
      Widgets.success("Wrote #{plist_path}")

      domain = "gui/#{uid()}"

      # bootout first in case it's already loaded (idempotent install)
      _ = System.cmd("launchctl", ["bootout", "#{domain}/#{@label}"], stderr_to_stdout: true)

      case System.cmd("launchctl", ["bootstrap", domain, plist_path], stderr_to_stdout: true) do
        {_out, 0} ->
          Widgets.success("Loaded LaunchAgent #{@label}")
          IO.puts("")
          IO.puts("Tail logs with:  egghead service logs")
          IO.puts("Stop with:       egghead service uninstall")

        {out, code} ->
          Widgets.error("launchctl bootstrap failed (exit #{code}): #{out}")
          System.halt(1)
      end
    end
  end

  defp install_linux(binary, config_path, log_path, working_dir, env_pairs, opts) do
    ensure_log_dir(log_path)

    exec_start = "#{binary} serve"

    unit =
      EEx.eval_string(@systemd_template,
        exec_start: exec_start,
        working_dir: working_dir,
        config_path: config_path,
        log_path: log_path,
        env_pairs: env_pairs
      )

    unit_dir =
      System.get_env("XDG_CONFIG_HOME") ||
        Path.join(working_dir, ".config")

    unit_path = Path.join([unit_dir, "systemd/user", @unit_filename])

    if opts[:dry_run] do
      IO.puts("# Would write #{unit_path}:\n")
      IO.puts(unit)
    else
      File.mkdir_p!(Path.dirname(unit_path))
      File.write!(unit_path, unit)
      Widgets.success("Wrote #{unit_path}")

      run_systemctl(["daemon-reload"])
      run_systemctl(["enable", "--now", "egghead.service"])

      Widgets.success("Enabled and started egghead.service")
      IO.puts("")
      IO.puts("Tail logs with:  egghead service logs")
      IO.puts("Stop with:       egghead service uninstall")
    end
  end

  # --- uninstall ---

  @doc false
  def uninstall(_args) do
    case platform() do
      :macos -> uninstall_macos()
      :linux -> uninstall_linux()
      other -> halt_unsupported(other)
    end
  end

  defp uninstall_macos do
    home = System.user_home!()
    plist_path = Path.join([home, "Library/LaunchAgents", @plist_filename])
    uid = uid()
    domain = "gui/#{uid}"

    _ = System.cmd("launchctl", ["bootout", "#{domain}/#{@label}"], stderr_to_stdout: true)

    if File.exists?(plist_path) do
      File.rm!(plist_path)
      Widgets.success("Removed #{plist_path}")
    else
      Widgets.warn("No LaunchAgent at #{plist_path}")
    end
  end

  defp uninstall_linux do
    home = System.user_home!()

    unit_dir =
      System.get_env("XDG_CONFIG_HOME") ||
        Path.join(home, ".config")

    unit_path = Path.join([unit_dir, "systemd/user", @unit_filename])

    _ = run_systemctl(["disable", "--now", "egghead.service"], allow_failure: true)

    if File.exists?(unit_path) do
      File.rm!(unit_path)
      Widgets.success("Removed #{unit_path}")
      run_systemctl(["daemon-reload"], allow_failure: true)
    else
      Widgets.warn("No systemd unit at #{unit_path}")
    end
  end

  # --- status ---

  @doc false
  def status(_args) do
    case platform() do
      :macos ->
        uid = uid()

        case System.cmd("launchctl", ["print", "gui/#{uid}/#{@label}"], stderr_to_stdout: true) do
          {out, 0} ->
            IO.puts(out)

          {out, _code} ->
            IO.puts(out)
            IO.puts("")
            IO.puts("Service is not loaded. Run `egghead service install`.")
        end

      :linux ->
        run_systemctl(["status", "egghead.service", "--no-pager"], allow_failure: true)

      other ->
        halt_unsupported(other)
    end
  end

  # --- helpers ---

  defp platform do
    case :os.type() do
      {:unix, :darwin} -> :macos
      {:unix, _} -> :linux
      other -> other
    end
  end

  defp halt_unsupported(other) do
    Widgets.error("Unsupported platform: #{inspect(other)}")
    System.halt(1)
  end

  # Resolve the binary that the unit should exec.
  #
  # Order:
  #   1. `egghead` on $PATH (Burrito-installed; the common case)
  #   2. ./bin/egghead from the working tree (dev fallback, returns :dev)
  #   3. give up
  @doc false
  def resolve_binary do
    cond do
      path = System.find_executable("egghead") ->
        {:ok, path, :installed}

      File.exists?(dev_binary_path()) ->
        {:ok, dev_binary_path(), :dev}

      true ->
        {:error,
         "Could not find an `egghead` binary on $PATH. Install via " <>
           "install.sh or `mix release` before running `service install`."}
    end
  end

  defp dev_binary_path do
    File.cwd!() |> Path.join("bin/egghead") |> Path.expand()
  end

  defp ensure_log_dir(log_path) do
    log_path |> Path.dirname() |> File.mkdir_p!()
  end

  # Scan config.yml for {env:VAR} references whose values are currently
  # set in the install shell. Offer to bake each one into the unit.
  defp collect_env_pairs(opts) do
    case File.read(Config.config_path()) do
      {:ok, content} ->
        refs =
          Regex.scan(~r/\{env:([A-Z_][A-Z0-9_]*)\}/, content, capture: :all_but_first)
          |> List.flatten()
          |> Enum.uniq()

        present = Enum.filter(refs, &(System.get_env(&1) not in [nil, ""]))

        cond do
          present == [] ->
            []

          opts[:yes] ->
            Enum.map(present, &{&1, System.get_env(&1)})

          true ->
            prompt_env_pairs(present, refs)
        end

      _ ->
        []
    end
  end

  defp prompt_env_pairs(present, all_refs) do
    missing = all_refs -- present

    IO.puts("")
    IO.puts("Your config references these environment variables via {env:...}:")

    for ref <- all_refs do
      tag = if ref in present, do: "set", else: Widgets.dim("not set in this shell")
      IO.puts("  #{Widgets.pad(ref, 24)} #{tag}")
    end

    if missing != [] do
      IO.puts("")
      Widgets.warn("Variables not set in this shell will not be captured.")
      IO.puts("Set them and re-run, or replace `{env:...}` with literal values in your config.")
    end

    IO.puts("")

    if Widgets.confirm("Bake the set values into the service unit?") do
      Enum.map(present, &{&1, System.get_env(&1)})
    else
      []
    end
  end

  defp uid do
    case System.cmd("id", ["-u"]) do
      {out, 0} -> String.trim(out)
      _ -> "0"
    end
  end

  defp run_systemctl(args, opts \\ []) do
    full = ["--user" | args]

    case System.cmd("systemctl", full, stderr_to_stdout: true) do
      {out, 0} ->
        IO.write(out)
        :ok

      {out, code} ->
        if Keyword.get(opts, :allow_failure, false) do
          IO.write(out)
          :ok
        else
          Widgets.error("systemctl --user #{Enum.join(args, " ")} failed (#{code}):\n#{out}")
          System.halt(1)
        end
    end
  end
end
