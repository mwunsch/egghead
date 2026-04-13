defmodule Mix.Tasks.Egghead.Config do
  @moduledoc """
  View and edit Egghead configuration.

      mix egghead.config              Show current configuration
      mix egghead.config set KEY VAL  Set a value (dot-path, e.g. web.port)
      mix egghead.config path         Print config file path
  """

  use Mix.Task

  alias Egghead.CLI.Widgets
  alias Egghead.Config

  @shortdoc "View/edit configuration"

  @help """
  Usage: egghead config [command] [options]

  View and modify Egghead configuration.

  Commands:
    (default)        Show current configuration
    set <key> <val>  Set a config value using dot-path notation
    path             Print the config file path

  Examples:
    egghead config
    egghead config set web.port 8080
    egghead config set default_model anthropic/claude-opus-4-6
    egghead config path

  Options:
    --help, -h       Show this help
  """

  @impl true
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args, switches: [help: :boolean, config: :string], aliases: [h: :help])

    if opts[:config], do: System.put_env("EGGHEAD_CONFIG", Path.expand(opts[:config]))

    if opts[:help] do
      IO.puts(@help)
    else
      case rest do
        ["path"] -> IO.puts(Config.config_path())
        ["set", key, value] -> do_set(key, value)
        [] -> show_config()
        _ -> IO.puts(@help)
      end
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
