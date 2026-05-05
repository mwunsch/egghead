defmodule Egghead.CLI.Doctor do
  @moduledoc false

  alias Egghead.Capability.Catalog
  alias Egghead.Capability.Validate
  alias Egghead.CLI.Widgets
  alias Egghead.Config

  def run(args) do
    if "--help" in args or "-h" in args do
      IO.puts("""
      USAGE
        egghead doctor [flags]

      DESCRIPTION
        Run diagnostic checks on your Egghead installation. Verifies that
        configuration, records directory, database index, NIF binaries,
        network ports, and LLM providers are all working correctly.

      CHECKS
        - Config file exists and is valid YAML
        - Records directory is accessible
        - SQLite index is present
        - NIF/OpenTUI binary exists for this platform
        - Web endpoint is reachable (or port available if standalone)
        - Log file is writable
        - Sandbox backend (sandbox-exec on macOS, bwrap on Linux)
        - inotify-tools available (Linux only)
        - Each LLM provider is reachable
        - Agent capability hygiene (malformed yaml, escalation risks,
          external grants with no hoistable sandbox root)

      FLAGS
        --config PATH   Override config file location
        -h, --help      Show this help

      SEE ALSO
        egghead config, egghead llm test
      """)
    else
      do_run()
    end
  end

  defp do_run do
    # Start the OTP application (record store, index, agent sync) so
    # capability audit can iterate agent records. Uses the shared
    # spinner helper so cold boot shows progress instead of looking
    # like the command has stalled.
    Egghead.CLI.prepare_runtime()

    IO.puts("")
    Widgets.puts("\e[1mEgghead Doctor\e[0m")
    IO.puts("")

    checks =
      [
        {"Config file", &check_config/0},
        {"Records directory", &check_records_dir/0},
        {"SQLite index", &check_index/0},
        {"NIF binary", &check_nif/0},
        {"Web endpoint", &check_web_endpoint/0},
        {"Log file", &check_log_file/0},
        {"Sandbox backend", &check_sandbox/0},
        {"BEAM cookie", &check_cookie/0}
      ] ++ linux_only([{"inotify-tools", &check_inotify/0}])

    results =
      Enum.map(checks, fn {name, check_fn} ->
        result = check_fn.()
        print_result(name, result)
        result
      end)

    provider_results = check_providers()
    capability_results = check_agent_capabilities()

    all_results = results ++ provider_results ++ capability_results
    passed = Enum.count(all_results, &match?(:ok, &1))
    failed = Enum.count(all_results, &match?({:error, _}, &1))
    warned = Enum.count(all_results, &match?({:warn, _}, &1))

    IO.puts("")

    summary = "#{passed} passed"
    summary = if failed > 0, do: summary <> ", #{failed} failed", else: summary
    summary = if warned > 0, do: summary <> ", #{warned} warnings", else: summary
    IO.puts(summary)
  end

  defp check_config do
    case Config.load() do
      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        {:error, "not found at #{Config.config_path()} — run `egghead init`"}

      {:error, {:invalid, reason}} ->
        {:error, "invalid YAML: #{inspect(reason)}"}
    end
  end

  defp check_records_dir do
    case Config.load() do
      {:ok, config} ->
        dir = Config.records_dir(config)

        cond do
          not File.dir?(dir) -> {:error, "#{dir} does not exist"}
          not writable?(dir) -> {:error, "#{dir} is not writable"}
          true -> :ok
        end

      {:error, _} ->
        dir = Path.expand("~/.egghead")
        if File.dir?(dir), do: :ok, else: {:warn, "default directory #{dir} does not exist yet"}
    end
  end

  defp check_index do
    case Config.load() do
      {:ok, config} ->
        dir = Config.records_dir(config)
        db_path = Path.join(dir, ".egghead/index.db")
        if File.exists?(db_path), do: :ok, else: {:warn, "will be created on first run"}

      {:error, _} ->
        {:warn, "no config — skipped"}
    end
  end

  defp check_nif do
    priv_dir = :code.priv_dir(:egghead) |> to_string()

    # Check all possible target subdirectories
    matches = Path.wildcard(Path.join(priv_dir, "*/lib/libopentui.*"))

    if matches != [] do
      :ok
    else
      {:error, "OpenTUI library not found in #{priv_dir}"}
    end
  rescue
    _ -> {:warn, "could not locate priv directory"}
  end

  # Two meaningful modes:
  #
  # - Client mode (another Egghead is already running): HEAD the
  #   server's `/health` endpoint to confirm the web UI is actually
  #   reachable, not just that a node is registered with epmd.
  # - Standalone: port-availability precheck for `egghead serve`.
  defp check_web_endpoint do
    {host, port} = web_host_port()

    if Egghead.Node.connected?() do
      ping_health(host, port)
    else
      check_port_available(port)
    end
  end

  defp ping_health(host, port) do
    Application.ensure_all_started(:req)
    url = "http://#{host}:#{port}/health"

    case Req.get(url, receive_timeout: 2_000, retry: false) do
      {:ok, %{status: 200}} ->
        {:ok, "reachable at #{host}:#{port}"}

      {:ok, %{status: status}} ->
        {:warn, "#{url} returned HTTP #{status}"}

      {:error, reason} ->
        {:warn, "#{url} unreachable: #{inspect(reason)}"}
    end
  end

  defp check_port_available(port) do
    case :gen_tcp.listen(port, []) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        {:ok, "port #{port} available"}

      {:error, :eaddrinuse} ->
        {:warn, "port #{port} is in use (something else is listening)"}

      {:error, reason} ->
        {:error, "port #{port}: #{inspect(reason)}"}
    end
  end

  defp web_host_port do
    case Config.load() do
      {:ok, config} -> {config.web.host, config.web.port}
      _ -> {"localhost", 4000}
    end
  end

  # Egghead's record store uses `file_system`, which on Linux shells out
  # to `inotifywait` from inotify-tools. Without it, edits to records
  # made outside egghead (editor saves, MCP writes, git pull, Obsidian)
  # don't trigger reindex until the next process restart.
  defp check_inotify do
    case System.find_executable("inotifywait") do
      nil ->
        {:error,
         "inotifywait not found — file watcher disabled. " <>
           "Install: sudo apt-get install inotify-tools (Debian/Ubuntu) " <>
           "| sudo dnf install inotify-tools (Fedora) " <>
           "| sudo pacman -S inotify-tools (Arch)"}

      _path ->
        :ok
    end
  end

  defp linux_only(checks) do
    case :os.type() do
      {:unix, :linux} -> checks
      _ -> []
    end
  end

  # Verifies the kernel-level sandbox binary is present on this machine.
  # macOS ships `sandbox-exec` at `/usr/bin/sandbox-exec` — always there
  # but Apple has technically deprecated it; we ride it anyway because no
  # command-line replacement exists. Linux needs `bwrap` (bubblewrap), a
  # small package from every major distro. Unsupported platforms (Windows,
  # BSDs) fall back to unsandboxed and we say so plainly.
  defp check_sandbox do
    case :os.type() do
      {:unix, :darwin} ->
        case System.find_executable("sandbox-exec") do
          nil ->
            {:error,
             "sandbox-exec not found — proc.* tools will run unsandboxed. " <>
               "This should be part of macOS by default; something is very wrong."}

          path ->
            {:ok, "sandbox-exec at #{path}"}
        end

      {:unix, :linux} ->
        case System.find_executable("bwrap") do
          nil ->
            {:error,
             "bwrap (bubblewrap) not found — proc.* tools will run unsandboxed. " <>
               "Install: sudo apt install bubblewrap (Debian/Ubuntu) " <>
               "| sudo dnf install bubblewrap (Fedora) " <>
               "| sudo pacman -S bubblewrap (Arch)"}

          path ->
            {:ok, "bwrap at #{path}"}
        end

      other ->
        {:warn,
         "unsupported platform #{inspect(other)} — proc.* tools run unsandboxed. " <>
           "Filesystem grants stay advisory (Elixir-level canonicalize + prefix check)."}
    end
  end

  # Cross-host distribution requires the same `~/.erlang.cookie` on both
  # ends. We check it strictly only when the operator has signaled cross-host
  # intent (`server.host` set, or `EGGHEAD_SERVER` exported); otherwise the
  # cookie is informational — Erlang generates it on first named-node start.
  defp check_cookie do
    path = Path.join(System.user_home!(), ".erlang.cookie")
    cross_host = cross_host_intent?()

    case File.stat(path) do
      {:ok, %{size: size, access: access}} ->
        cond do
          size == 0 ->
            {:error, "#{path} is empty"}

          access not in [:read, :read_write] ->
            {:error, "#{path} is not readable"}

          true ->
            {:ok, "present (#{size} bytes)"}
        end

      {:error, :enoent} ->
        if cross_host do
          {:error,
           "no #{path} — cross-host distribution requires it. " <>
             "Run `egghead serve` once locally to generate, then copy to peer hosts."}
        else
          {:warn, "no #{path} yet (created on first named-node start)"}
        end

      {:error, reason} ->
        {:error, "#{path}: #{inspect(reason)}"}
    end
  end

  defp cross_host_intent? do
    has_env = (System.get_env("EGGHEAD_SERVER") || "") != ""

    has_host =
      case Config.load() do
        {:ok, %{server: %{host: host}}} when is_binary(host) and host != "" -> true
        _ -> false
      end

    has_env or has_host
  end

  defp check_log_file do
    log_file = Config.log_path()
    log_dir = Path.dirname(log_file)

    cond do
      File.exists?(log_file) and writable?(log_file) ->
        :ok

      File.exists?(log_file) ->
        {:error, "#{log_file} is not writable"}

      writable?(log_dir) ->
        :ok

      File.dir?(log_dir) ->
        {:error, "#{log_dir} is not writable"}

      true ->
        {:warn, "log directory #{log_dir} does not exist yet (will be created on first run)"}
    end
  end

  defp check_providers do
    case Config.load() do
      {:ok, %Config{llm: entries}} when entries != [] ->
        IO.puts("")
        IO.puts("  LLM Providers:")
        Application.ensure_all_started(:req)

        Enum.map(entries, fn entry ->
          name = entry[:name] || entry.provider
          api_key = Config.resolve_value(entry.api_key)

          result =
            if api_key do
              module = Egghead.LLM.Registry.determine_module(entry.provider)
              Code.ensure_loaded(module)

              if function_exported?(module, :list_models, 1) do
                opts =
                  [api_key: api_key]
                  |> then(fn o ->
                    if entry[:base_url], do: Keyword.put(o, :base_url, entry.base_url), else: o
                  end)

                case module.list_models(opts) do
                  {:ok, models} -> {:ok, "#{length(models)} models"}
                  {:error, reason} -> {:error, inspect(reason)}
                end
              else
                :ok
              end
            else
              {:error, "no API key"}
            end

          print_result("  #{name}", result)
          result
        end)

      _ ->
        [{:warn, "no providers configured"}]
    end
  end

  # Iterate every :agent record, validate its `capabilities:` yaml
  # against the Catalog schema, flag escalation-risk scopes
  # (fs.write/fs.delete covering the records directory, proc.exec
  # with no command/pattern restriction), and render the capability
  # list with the same risk-marker + short-label style as
  # `egghead agents capabilities`. Issues warn rather than fail —
  # records always load; this just surfaces problems.
  defp check_agent_capabilities do
    records = safe_list_class(:agent)

    IO.puts("")
    IO.puts("  Agent capabilities:")

    case records do
      [] ->
        IO.puts("      (no agent records)")
        [:ok]

      records ->
        records_dir = records_dir()
        Enum.map(records, &audit_and_print(&1, records_dir))
    end
  end

  defp audit_and_print(record, records_dir) do
    meta = record.meta || %{}
    raw = Map.get(meta, "capabilities")
    agent_sandbox = Map.get(meta, "sandbox")
    config_sandbox = config_sandbox()

    issues =
      case Validate.validate(raw) do
        :ok -> []
        {:error, problems} -> Enum.map(problems, & &1.problem)
      end

    escalations = Validate.escalation_warnings(raw, records_dir)
    dangling = Validate.sandbox_warnings(raw, agent_sandbox, config_sandbox)
    warnings = issues ++ escalations ++ dangling

    result = if warnings == [], do: :ok, else: {:warn, Enum.join(warnings, "; ")}

    # Status line in the same style as the providers section: icon
    # at column 0, name indented two spaces.
    case result do
      :ok -> Widgets.success("  #{record.id}")
      {:warn, _} -> Widgets.warn("  #{record.id}")
    end

    render_capability_list(record)
    Enum.each(warnings, fn w -> Widgets.puts("      \e[33m⚠\e[0m #{w}") end)

    result
  end

  # Display the agent's *effective* capabilities — the same list the live
  # agent GenServer holds. Routes through `Record.Agent.parse_capabilities/1`
  # so `access:` expansion, `sandbox:` expansion, and the no-keys default
  # (`records.read`) all apply. Reading `meta["capabilities"]` directly
  # would silently under-report any agent that relied on those shortcuts.
  defp render_capability_list(record) do
    grants = parse_agent_safely(record)

    cond do
      grants == [] ->
        IO.puts("      (none)")

      true ->
        grants
        |> Catalog.sort_by_risk()
        |> Enum.each(fn grant ->
          marker = risk_marker(Catalog.risk(grant))
          IO.puts("      #{marker} #{Catalog.describe(grant)}")
        end)
    end
  end

  # `Record.Agent.parse_capabilities/1` logs warnings for malformed
  # entries. For the doctor display we tolerate bad input silently
  # and continue — the validation pass above already surfaced the
  # issues as warning lines.
  defp parse_agent_safely(record) do
    Egghead.Record.Agent.parse_capabilities(record)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp risk_marker(:low), do: "\e[32m●\e[0m"
  defp risk_marker(:medium), do: "\e[33m●\e[0m"
  defp risk_marker(:high), do: "\e[31m●\e[0m"
  defp risk_marker(_), do: "○"

  defp records_dir do
    case Config.load() do
      {:ok, config} -> Config.records_dir(config) |> Path.expand()
      _ -> nil
    end
  end

  defp config_sandbox do
    case Config.load() do
      {:ok, config} -> Config.sandbox(config)
      _ -> nil
    end
  end

  defp safe_list_class(class) do
    Egghead.list_records()
    |> Enum.filter(&(&1.class == class))
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp print_result(name, :ok), do: Widgets.success(name)
  defp print_result(name, {:ok, detail}), do: Widgets.puts("\e[32m✓\e[0m #{name} — #{detail}")
  defp print_result(name, {:warn, detail}), do: Widgets.warn("#{name} — #{detail}")
  defp print_result(name, {:error, detail}), do: Widgets.error("#{name} — #{detail}")

  defp writable?(path) do
    case File.stat(path) do
      {:ok, %{access: access}} -> access in [:write, :read_write]
      _ -> false
    end
  end
end
