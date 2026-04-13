defmodule Mix.Tasks.Egghead.Llm do
  @moduledoc """
  Manage LLM providers.

      mix egghead.llm              Show configured providers
      mix egghead.llm list         Show configured providers
      mix egghead.llm add          Add a provider
      mix egghead.llm remove NAME  Remove a provider
      mix egghead.llm test         Verify providers work
      mix egghead.llm models       List all discovered models
  """

  use Mix.Task

  alias Egghead.CLI.Widgets
  alias Egghead.Config

  @shortdoc "Manage LLM providers"

  @impl true
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args, switches: [help: :boolean, config: :string], aliases: [h: :help])

    if opts[:config], do: System.put_env("EGGHEAD_CONFIG", Path.expand(opts[:config]))

    if opts[:help] do
      IO.puts("Usage: egghead llm <command> [--help]")
      IO.puts("Commands: list, add, remove <name>, test, models")
    else
      case rest do
        ["list"] ->
          do_list()

        ["add"] ->
          do_add()

        ["remove", name] ->
          do_remove(name)

        ["test"] ->
          do_test()

        ["models"] ->
          do_models()

        [] ->
          do_list()

        _ ->
          IO.puts(
            "Usage: egghead llm <command>\nCommands: list, add, remove <name>, test, models"
          )
      end
    end
  end

  defp do_list do
    case Config.load() do
      {:ok, %Config{llm: entries}} when entries != [] ->
        Widgets.header("Configured LLM Providers")

        Enum.each(entries, fn entry ->
          key_status =
            case entry.api_key do
              nil ->
                "\e[33mno key\e[0m"

              key when is_binary(key) ->
                if String.starts_with?(key, "{env:") do
                  resolved = Config.resolve_value(key)
                  if resolved, do: "\e[32m✓ via env\e[0m", else: "\e[31m✗ env not set\e[0m"
                else
                  "\e[32m✓\e[0m"
                end

              _ ->
                "\e[33m?\e[0m"
            end

          name = entry[:name] || entry.provider
          base = if entry[:base_url], do: " (#{entry.base_url})", else: ""
          IO.puts("  #{name}#{base}  #{key_status}")
        end)

      {:ok, %Config{llm: []}} ->
        IO.puts("No LLM providers configured.")
        IO.puts("Run `egghead llm add` to add one.")

      {:error, :not_found} ->
        IO.puts("No configuration file found.")
        IO.puts("Run `egghead init` to set up Egghead.")

      {:error, reason} ->
        Widgets.error("Failed to load config: #{inspect(reason)}")
    end
  end

  defp do_add do
    config =
      case Config.load() do
        {:ok, config} -> config
        _ -> %Config{}
      end

    {updated, _models} = Mix.Tasks.Egghead.Init.add_provider(config)

    case Config.save(updated) do
      :ok -> Widgets.success("Configuration saved.")
      {:error, reason} -> Widgets.error("Failed to save: #{inspect(reason)}")
    end
  end

  defp do_remove(name) do
    case Config.load() do
      {:ok, config} ->
        original_count = length(config.llm)

        updated_llm =
          Enum.reject(config.llm, fn entry ->
            entry.provider == name || entry[:name] == name
          end)

        if length(updated_llm) == original_count do
          Widgets.error("Provider '#{name}' not found.")
        else
          updated = %{config | llm: updated_llm}

          case Config.save(updated) do
            :ok -> Widgets.success("Removed '#{name}'.")
            {:error, reason} -> Widgets.error("Failed to save: #{inspect(reason)}")
          end
        end

      {:error, :not_found} ->
        IO.puts("No configuration file found. Run `egghead init` first.")

      {:error, reason} ->
        Widgets.error("Failed to load config: #{inspect(reason)}")
    end
  end

  defp do_test do
    Widgets.start_app()

    providers = Egghead.LLM.Registry.list_providers()

    if providers == [] do
      IO.puts("No providers configured.")
    else
      Widgets.header("Testing LLM Providers")

      Enum.each(providers, fn provider ->
        result =
          if provider.has_key do
            models = Egghead.LLM.Registry.list_models()
            count = Enum.count(models, &(&1.provider == provider.name))
            {:ok, count}
          else
            {:error, "no API key"}
          end

        case result do
          {:ok, count} -> Widgets.success("#{provider.name} — #{count} models")
          {:error, msg} -> Widgets.error("#{provider.name} — #{msg}")
        end
      end)
    end
  end

  defp do_models do
    Widgets.start_app()

    models =
      Widgets.spinner("Discovering models...", fn ->
        Egghead.LLM.Registry.await_discovery()
        Egghead.LLM.Registry.list_models()
      end)

    if models == [] do
      IO.puts("No models found. Check your provider configuration.")
    else
      Widgets.header("Available Models")

      models
      |> Enum.group_by(& &1.provider)
      |> Enum.sort_by(fn {provider, _} -> provider end)
      |> Enum.each(fn {provider, provider_models} ->
        IO.puts("  \e[1m#{provider}\e[0m")

        provider_models
        |> Enum.sort_by(& &1.id)
        |> Enum.each(fn model ->
          ctx = Widgets.format_context(model[:context_window])
          IO.puts("    #{Widgets.pad(model.id, 32)} \e[90m#{ctx}\e[0m")
        end)
      end)
    end
  end
end
