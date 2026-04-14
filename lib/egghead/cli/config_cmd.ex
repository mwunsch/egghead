defmodule Egghead.CLI.ConfigCmd do
  @moduledoc "Configuration viewing and editing."

  alias Egghead.CLI.Widgets
  alias Egghead.Config

  def run(args) do
    if "--help" in args or "-h" in args do
      IO.puts("""
      USAGE
        egghead config [command] [flags]

      DESCRIPTION
        View and modify Egghead configuration. Config is stored in YAML at
        ~/.config/egghead/config.yml (respects $XDG_CONFIG_HOME).

      COMMANDS
        (default)         Show current configuration
        set <key> <val>   Set a config value using dot-path notation
        path              Print the config file path

      FLAGS
        -h, --help        Show this help

      EXAMPLES
        $ egghead config
        $ egghead config path
        $ egghead config set web.port 8080
        $ egghead config set default_model anthropic/claude-opus-4-6

      SEE ALSO
        egghead init, egghead doctor
      """)
    else
      dispatch(args)
    end
  end

  defp dispatch(args) do
    case args do
      ["path" | _] -> IO.puts(Config.config_path())
      ["set", key, value | _] -> do_set(key, value)
      [] -> show_config()
      _ -> IO.puts("Usage: egghead config [set <key> <val> | path]")
    end
  end

  defp do_set(key, value) do
    case Config.set(key, value) do
      :ok -> Widgets.success("Set #{key} = #{value}")
      {:error, reason} -> Widgets.error("Failed: #{inspect(reason)}")
    end
  end

  defp show_config do
    case Config.load() do
      {:ok, config} ->
        Widgets.header("Egghead Configuration")
        IO.puts("  File: #{Config.config_path()}")
        IO.puts("")
        IO.puts("  records_dir:   #{config.records_dir}")
        IO.puts("  default_model: #{config.default_model || "(not set)"}")
        IO.puts("")

        if config.llm != [] do
          IO.puts("  LLM Providers:")

          Enum.each(config.llm, fn entry ->
            name = entry[:name] || entry.provider
            key_hint = if entry.api_key, do: " (key set)", else: " (no key)"
            base = if entry[:base_url], do: " @ #{entry.base_url}", else: ""
            IO.puts("    #{name}#{key_hint}#{base}")
          end)

          IO.puts("")
        end

        IO.puts("  Web:")
        IO.puts("    port: #{config.web.port}")
        IO.puts("    host: #{config.web.host}")
        IO.puts("    bind: #{config.web.bind}")

      {:error, :not_found} ->
        IO.puts("No configuration file found at #{Config.config_path()}")
        IO.puts("Run `egghead init` to create one.")

      {:error, reason} ->
        Widgets.error("Failed to load config: #{inspect(reason)}")
    end
  end
end
