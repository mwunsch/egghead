defmodule Egghead.CLI.Init do
  @moduledoc false

  alias Egghead.CLI.Widgets
  alias Egghead.Config

  @known_providers [
    %{name: "Anthropic", id: "anthropic", hint: "Claude models"},
    %{name: "OpenAI", id: "openai", hint: "GPT, o-series models"},
    %{name: "Google", id: "google", hint: "Gemini models"},
    %{name: "xAI", id: "xai", hint: "Grok models"},
    %{name: "Groq", id: "groq", hint: "Fast inference of open models"},
    %{name: "DeepSeek", id: "deepseek", hint: "DeepSeek V3/R1, reasoning"},
    %{name: "Mistral", id: "mistral", hint: "Mistral Large / Medium / Small"},
    %{name: "OpenRouter", id: "openrouter", hint: "300+ models via one key"},
    %{name: "Ollama", id: "ollama", hint: "Local models (localhost:11434)"},
    %{name: "LM Studio", id: "lmstudio", hint: "Local models (localhost:1234)"},
    %{name: "Custom", id: "custom", hint: "Any OpenAI-compatible endpoint"}
  ]

  def run(args) do
    if "--help" in args or "-h" in args do
      IO.puts("""
      USAGE
        egghead init [flags]

      DESCRIPTION
        First-run setup wizard. Walks through records directory location,
        LLM provider configuration (API keys), and built-in agent model.
        Saves configuration to ~/.config/egghead/config.yml.

      FLAGS
        --config PATH   Save config to a custom path instead of the default
        --dry-run       Show what would be written without saving
        -h, --help      Show this help

      EXAMPLES
        $ egghead init
        $ egghead init --config ~/projects/my-kb/egghead.yml
        $ egghead init --dry-run

      SEE ALSO
        egghead config, egghead llm, egghead doctor
      """)
    else
      {opts, _, _} =
        OptionParser.parse(args,
          switches: [dry_run: :boolean],
          aliases: []
        )

      do_init(opts)
    end
  end

  defp do_init(opts) do
    dry_run = opts[:dry_run] || false

    if Config.exists?() and not dry_run do
      unless Widgets.confirm("Config already exists at #{Config.config_path()}. Overwrite?") do
        IO.puts("Aborted.")
        return()
      end
    end

    IO.puts("")
    IO.puts("\e[1mWelcome to Egghead.\e[0m")
    IO.puts("")

    Widgets.header("Records directory")
    records_dir = Widgets.input("Where should records live?", default: "~/.egghead")
    expanded = Path.expand(records_dir)

    if not dry_run and not File.dir?(expanded) do
      File.mkdir_p!(expanded)
      Widgets.success("Created #{expanded}")
    end

    config = %Config{records_dir: records_dir, llm: []}
    {config, discovered_models} = add_providers_loop(config, [])

    config =
      if discovered_models != [] do
        pick_initial_model(config, discovered_models)
      else
        config
      end

    if dry_run do
      Widgets.header("Dry run — would write to #{Config.config_path()}:")
      IO.puts("")
      IO.puts(config |> Map.from_struct() |> inspect(pretty: true))
    else
      case Config.save(config) do
        :ok ->
          IO.puts("")
          Widgets.success("Configuration saved to #{Config.config_path()}")
          maybe_install_service()

        {:error, reason} ->
          Widgets.error("Failed to save config: #{inspect(reason)}")
      end
    end
  end

  defp maybe_install_service do
    case :os.type() do
      {:unix, _} ->
        IO.puts("")
        Widgets.header("Background service")

        IO.puts(
          "Egghead can run as a background service so it starts at login\n" <>
            "and survives logout. Logs go to the standard XDG log file."
        )

        IO.puts("")

        if Widgets.confirm("Install the background service now?") do
          Egghead.CLI.Service.install([])
        else
          IO.puts("Skipped. Run `egghead service install` later if you change your mind.")
        end

      _ ->
        :ok
    end
  end

  @doc """
  Runs the LLM add flow and returns `{updated_config, discovered_models}`.
  Shared by init and llm add.
  """
  def add_provider(config) do
    Widgets.header("Add LLM Provider")

    provider =
      Widgets.select(@known_providers,
        label: "Select a provider:",
        render_as: fn p ->
          "#{Widgets.pad(p.name, 14)} #{Widgets.dim(p.hint)}"
        end
      )

    if is_nil(provider) do
      {config, []}
    else
      preset = Egghead.LLM.Registry.preset(provider.id)
      {raw_key, base_url} = prompt_credentials(provider, preset)
      api_key = resolve_or_env_ref(raw_key, provider.id, preset)

      entry = %{
        provider: provider.id,
        api_key: api_key,
        base_url: base_url,
        name: if(provider.id == "custom", do: "custom")
      }

      # Local runners (Ollama / LM Studio) are valid with no key.
      proceed? = api_key != nil or (preset && Map.get(preset, :optional_key))

      if proceed? do
        result =
          Widgets.spinner("Verifying #{provider.name}...", fn ->
            verify_provider(entry)
          end)

        case result do
          {:ok, models} ->
            Widgets.success("#{provider.name} connected — #{length(models)} models available")
            cleaned = Enum.reject(config.llm, &(&1.provider == provider.id))
            {%{config | llm: cleaned ++ [entry]}, models}

          {:error, reason} ->
            Widgets.error("Verification failed: #{inspect(reason)}")
            Widgets.warn("Provider not added. Check your endpoint and key and try again.")
            {config, []}
        end
      else
        {config, []}
      end
    end
  end

  defp prompt_credentials(%{id: "custom"}, _preset) do
    key = Widgets.secret("API key (or press Enter for none)")
    url = Widgets.input("Base URL", default: "http://localhost:11434/v1")
    {key, url}
  end

  defp prompt_credentials(provider, nil) do
    # Native provider with no preset entry (anthropic / openai / google).
    key = Widgets.secret(api_key_prompt(provider.id))
    {key, nil}
  end

  defp prompt_credentials(provider, preset) do
    base_url = Map.get(preset, :base_url)

    key =
      if Map.get(preset, :optional_key) do
        Widgets.secret("API key (leave empty for local)")
      else
        Widgets.secret(api_key_prompt(provider.id))
      end

    {key, base_url}
  end

  defp api_key_prompt(provider_id) do
    case Egghead.LLM.Registry.env_vars(provider_id) do
      [env | _] -> "API key (or leave empty to use $#{env})"
      [] -> "API key"
    end
  end

  # Turn a user-entered key into a config value:
  # - empty input + known env var → store `"{env:XXX}"` so it resolves at runtime
  # - empty input + no env var → nil (skip adding unless preset says key is optional)
  # - any non-empty input → use verbatim
  defp resolve_or_env_ref("", provider_id, _preset) do
    case Egghead.LLM.Registry.env_vars(provider_id) do
      [env | _] -> "{env:#{env}}"
      [] -> nil
    end
  end

  defp resolve_or_env_ref(nil, provider_id, preset),
    do: resolve_or_env_ref("", provider_id, preset)

  defp resolve_or_env_ref(key, _provider_id, _preset), do: key

  defp add_providers_loop(config, all_models) do
    {config, models} = add_provider(config)
    all_models = all_models ++ models

    if Widgets.confirm("Add another provider?") do
      add_providers_loop(config, all_models)
    else
      {config, all_models}
    end
  end

  defp pick_initial_model(config, models) do
    IO.puts("")
    IO.puts("Egghead comes with a built-in agent that helps you search")
    IO.puts("and navigate your records. Pick a model to power it.")
    IO.puts("A smaller, faster model works well here.")
    IO.puts("")

    selected =
      Widgets.select(models,
        label: "Model for the built-in agent:",
        render_as: fn m ->
          ctx = Widgets.format_context(m[:context_window])
          "#{Widgets.pad(m.full_id, 36)} #{Widgets.dim(ctx)}"
        end
      )

    if selected, do: %{config | default_model: selected.full_id}, else: config
  end

  defp verify_provider(entry) do
    module = Egghead.LLM.Registry.determine_module(entry.provider)

    opts =
      [api_key: entry.api_key]
      |> then(fn o ->
        if entry.base_url, do: Keyword.put(o, :base_url, entry.base_url), else: o
      end)

    Code.ensure_loaded(module)

    if function_exported?(module, :list_models, 1) do
      Application.ensure_all_started(:req)

      case module.list_models(opts) do
        {:ok, models} ->
          tagged = Enum.map(models, &Map.put(&1, :full_id, "#{entry.provider}/#{&1.id}"))
          {:ok, tagged}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, []}
    end
  end

  defp return, do: :ok
end
