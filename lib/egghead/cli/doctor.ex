defmodule Egghead.CLI.Doctor do
  @moduledoc "Diagnostic checks."

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
        - Web port is available
        - Log file is writable
        - inotify-tools available (Linux only)
        - Each LLM provider is reachable

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
    IO.puts("")
    IO.puts("\e[1mEgghead Doctor\e[0m")
    IO.puts("")

    checks =
      [
        {"Config file", &check_config/0},
        {"Records directory", &check_records_dir/0},
        {"SQLite index", &check_index/0},
        {"NIF binary", &check_nif/0},
        {"Web port", &check_port/0},
        {"Log file", &check_log_file/0}
      ] ++ linux_only([{"inotify-tools", &check_inotify/0}])

    results =
      Enum.map(checks, fn {name, check_fn} ->
        result = check_fn.()
        print_result(name, result)
        result
      end)

    provider_results = check_providers()

    all_results = results ++ provider_results
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

  defp check_port do
    port =
      case Config.load() do
        {:ok, config} -> config.web.port
        _ -> 4000
      end

    case :gen_tcp.listen(port, []) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, :eaddrinuse} ->
        {:warn, "port #{port} is in use (Egghead may already be running)"}

      {:error, reason} ->
        {:error, "port #{port}: #{inspect(reason)}"}
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

  defp print_result(name, :ok), do: Widgets.success(name)
  defp print_result(name, {:ok, detail}), do: IO.puts("\e[32m✓\e[0m #{name} — #{detail}")
  defp print_result(name, {:warn, detail}), do: Widgets.warn("#{name} — #{detail}")
  defp print_result(name, {:error, detail}), do: Widgets.error("#{name} — #{detail}")

  defp writable?(path) do
    case File.stat(path) do
      {:ok, %{access: access}} -> access in [:write, :read_write]
      _ -> false
    end
  end
end
