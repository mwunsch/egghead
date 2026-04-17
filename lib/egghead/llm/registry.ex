defmodule Egghead.LLM.Registry do
  @moduledoc """
  Provider registry for LLM access.

  Manages configured providers, resolves `provider/model` strings,
  validates model availability, and handles credential resolution.

  ## Configuration layers (in precedence order)

  1. Egghead config file: `~/.config/egghead/config.yml` (llm section)
  2. Legacy project config: `records/.egghead/providers.yml`
  3. Legacy user config: `~/.egghead/providers.yml`
  4. Environment variables: auto-detects `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`

  ## Provider/model format

  Models are specified as `provider/model-id`, e.g. `anthropic/claude-sonnet-4-6`.
  Bare model names (e.g. `claude-sonnet-4-6`) are inferred to the matching provider.
  """

  use GenServer

  require Logger

  @known_providers %{
    "anthropic" => Egghead.LLM.Anthropic,
    "openai" => Egghead.LLM.OpenAI,
    "google" => Egghead.LLM.Google
  }

  @env_var_map %{
    "anthropic" => ["ANTHROPIC_API_KEY"],
    "openai" => ["OPENAI_API_KEY"],
    "google" => ["GOOGLE_API_KEY", "GEMINI_API_KEY"]
  }

  @model_prefixes %{
    "claude" => "anthropic",
    "gpt" => "openai",
    "o1" => "openai",
    "o3" => "openai",
    "o4" => "openai",
    "gemini" => "google"
  }

  defmodule ProviderConfig do
    @moduledoc false
    defstruct [
      :name,
      :module,
      :api_key,
      :base_url,
      :api,
      models: :auto,
      model_cache: nil
    ]
  end

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Resolves a `provider/model` string to `{:ok, {module, config}}` or `{:error, reason}`.

  Accepts:
  - `"anthropic/claude-sonnet-4-6"` — explicit provider/model
  - `"claude-sonnet-4-6"` — inferred provider from model name prefix
  - Backwards compat: separate `provider` + `model` atoms/strings
  """
  @spec resolve(GenServer.server(), String.t(), String.t() | nil) ::
          {:ok, {module(), keyword()}} | {:error, term()}
  def resolve(server \\ __MODULE__, model_str, fallback_provider \\ nil) do
    Egghead.Node.call(server, {:resolve, model_str, fallback_provider})
  end

  @doc """
  Lists all configured providers with their status.
  """
  @spec list_providers(GenServer.server()) :: [map()]
  def list_providers(server \\ __MODULE__) do
    Egghead.Node.call(server, :list_providers)
  end

  @doc """
  Lists all available models across all providers.
  """
  @spec list_models(GenServer.server()) :: [map()]
  def list_models(server \\ __MODULE__) do
    Egghead.Node.call(server, :list_models)
  end

  @doc """
  Gets the default model string (first configured provider's default).
  """
  @spec default_model(GenServer.server()) :: String.t()
  def default_model(server \\ __MODULE__) do
    Egghead.Node.call(server, :default_model)
  end

  @doc """
  Gets model info (context window, etc.) for a specific provider/model.
  """
  @spec get_model_info(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_model_info(server \\ __MODULE__, model_str) do
    Egghead.Node.call(server, {:get_model_info, model_str})
  end

  @doc """
  Blocks until model discovery completes. Returns `:ok` when all providers
  have finished their initial model listing, or `{:error, :timeout}` if
  the timeout expires.

  Use this instead of `Process.sleep` when you need models to be available.
  """
  @spec await_discovery(GenServer.server(), timeout()) :: :ok
  def await_discovery(server \\ __MODULE__, timeout \\ 10_000) do
    Egghead.Node.call(server, :await_discovery, timeout)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    records_dir = Keyword.get(opts, :records_dir)

    providers = load_config(records_dir)

    if providers == %{} do
      Logger.warning(
        "No LLM providers configured. Set ANTHROPIC_API_KEY, OPENAI_API_KEY, or GOOGLE_API_KEY, " <>
          "or run `egghead init`"
      )
    else
      names = providers |> Map.keys() |> Enum.join(", ")
      Logger.info("LLM providers configured: #{names}")
    end

    # Discover models asynchronously for auto-discovery providers
    send(self(), :discover_models)

    {:ok, %{providers: providers, discovery_ready: false, discovery_waiters: []}}
  end

  @impl true
  def handle_call({:resolve, model_str, fallback_provider}, _from, state) do
    result = do_resolve(state.providers, model_str, fallback_provider)
    {:reply, result, state}
  end

  def handle_call(:list_providers, _from, state) do
    providers =
      state.providers
      |> Enum.map(fn {name, config} ->
        %{
          name: name,
          module: config.module,
          api: config.api || provider_api_type(config.module),
          has_key: config.api_key != nil,
          base_url: config.base_url
        }
      end)

    {:reply, providers, state}
  end

  def handle_call(:list_models, _from, state) do
    models =
      state.providers
      |> Enum.flat_map(fn {provider_name, config} ->
        case get_cached_models(config) do
          {:ok, model_list} ->
            Enum.map(model_list, fn m ->
              Map.merge(m, %{provider: provider_name, full_id: "#{provider_name}/#{m.id}"})
            end)

          {:error, _} ->
            []
        end
      end)

    {:reply, models, state}
  end

  def handle_call(:default_model, _from, state) do
    default =
      cond do
        Map.has_key?(state.providers, "anthropic") -> "anthropic/claude-sonnet-4-6"
        Map.has_key?(state.providers, "openai") -> "openai/gpt-4o"
        Map.has_key?(state.providers, "google") -> "google/gemini-2.0-flash"
        true -> "anthropic/claude-sonnet-4-6"
      end

    {:reply, default, state}
  end

  def handle_call(:await_discovery, _from, %{discovery_ready: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:await_discovery, from, state) do
    {:noreply, %{state | discovery_waiters: [from | state.discovery_waiters]}}
  end

  def handle_call({:get_model_info, model_str}, _from, state) do
    case do_resolve(state.providers, model_str, nil) do
      {:ok, {module, opts}} ->
        model_id = Keyword.get(opts, :model)

        Code.ensure_loaded(module)

        if function_exported?(module, :get_model_info, 2) do
          result = module.get_model_info(model_id, opts)
          {:reply, result, state}
        else
          {:reply, {:error, :not_supported}, state}
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  # --- Config loading ---

  @impl true
  def handle_info(:discover_models, state) do
    providers =
      state.providers
      |> Enum.map(fn {name, config} ->
        case config.models do
          :auto ->
            Code.ensure_loaded(config.module)

            if function_exported?(config.module, :list_models, 1) do
              opts = [api_key: config.api_key] |> maybe_opt(:base_url, config.base_url)

              case config.module.list_models(opts) do
                {:ok, models} ->
                  Logger.info("Discovered #{length(models)} models for #{name}")
                  {name, %{config | model_cache: models}}

                {:error, reason} ->
                  Logger.warning("Model discovery failed for #{name}: #{inspect(reason)}")
                  {name, config}
              end
            else
              {name, config}
            end

          _ ->
            {name, config}
        end
      end)
      |> Map.new()

    # Notify anyone waiting for discovery to complete
    Enum.each(state.discovery_waiters, &GenServer.reply(&1, :ok))

    {:noreply, %{state | providers: providers, discovery_ready: true, discovery_waiters: []}}
  end

  # --- Config loading ---

  defp load_config(records_dir) do
    # Layer 1: New config.yml (llm section)
    new_config = load_egghead_config()

    # Layer 2: Legacy user config (~/.egghead/providers.yml)
    legacy_user = load_yaml_config(legacy_user_config_path())

    # Layer 3: Legacy project config (records/.egghead/providers.yml)
    legacy_project =
      if records_dir do
        load_yaml_config(Path.join(records_dir, ".egghead/providers.yml"))
      else
        %{}
      end

    # Merge: new config > legacy project > legacy user
    file_config =
      legacy_user
      |> Map.merge(legacy_project)
      |> Map.merge(new_config)

    # Layer 4: Env var auto-detection for providers not in file config
    env_config = detect_env_providers(file_config)

    # Merge: file config takes precedence over env detection
    Map.merge(env_config, file_config)
  end

  defp load_egghead_config do
    case Egghead.Config.load() do
      {:ok, %Egghead.Config{llm: entries}} when entries != [] ->
        entries
        |> Enum.map(fn entry ->
          name = entry.provider
          api_key = Egghead.Config.resolve_value(entry.api_key)
          module = determine_module(name, nil)

          config = %ProviderConfig{
            name: name,
            module: module,
            api_key: api_key,
            base_url: entry[:base_url],
            models: :auto
          }

          {name, config}
        end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp load_yaml_config(path) do
    case File.read(path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, %{"providers" => providers}} when is_map(providers) ->
            providers
            |> Enum.map(fn {name, config} -> {name, parse_provider_config(name, config)} end)
            |> Map.new()

          _ ->
            %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp parse_provider_config(name, config) when is_map(config) do
    api_key = resolve_value(config["api_key"])
    api = config["api"]
    module = determine_module(name, api)

    models =
      case config["models"] do
        "auto" -> :auto
        list when is_list(list) -> Enum.map(list, &parse_model_entry/1)
        _ -> :auto
      end

    %ProviderConfig{
      name: name,
      module: module,
      api_key: api_key,
      base_url: config["base_url"],
      api: api,
      models: models
    }
  end

  defp parse_provider_config(name, _) do
    %ProviderConfig{name: name, module: Egghead.LLM.OpenAI}
  end

  defp parse_model_entry(entry) when is_map(entry) do
    %{
      id: entry["id"],
      context_window: entry["context_window"],
      max_tokens: entry["max_tokens"]
    }
  end

  defp parse_model_entry(id) when is_binary(id), do: %{id: id}

  @doc "Returns the LLM provider module for a given provider name."
  def determine_module(name, api \\ nil) do
    cond do
      api == "openai_compatible" -> Egghead.LLM.OpenAI
      Map.has_key?(@known_providers, name) -> @known_providers[name]
      true -> Egghead.LLM.OpenAI
    end
  end

  defp detect_env_providers(existing) do
    @env_var_map
    |> Enum.reduce(%{}, fn {provider_name, env_vars}, acc ->
      if Map.has_key?(existing, provider_name) do
        acc
      else
        case find_env_var(env_vars) do
          nil ->
            acc

          api_key ->
            module = @known_providers[provider_name]

            config = %ProviderConfig{
              name: provider_name,
              module: module,
              api_key: api_key,
              models: :auto
            }

            Map.put(acc, provider_name, config)
        end
      end
    end)
  end

  defp find_env_var(var_names) do
    Enum.find_value(var_names, fn name ->
      case System.get_env(name) do
        nil -> nil
        "" -> nil
        val -> val
      end
    end)
  end

  defp resolve_value(value), do: Egghead.Config.resolve_value(value)

  # --- Model resolution ---

  defp do_resolve(providers, model_str, fallback_provider) do
    {provider_name, model_id} = parse_model_string(model_str, fallback_provider)

    case Map.get(providers, provider_name) do
      nil ->
        {:error, {:provider_not_configured, provider_name}}

      config ->
        opts =
          [
            model: model_id,
            api_key: config.api_key
          ]
          |> maybe_opt(:base_url, config.base_url)

        {:ok, {config.module, opts}}
    end
  end

  defp parse_model_string(model_str, fallback_provider) do
    case String.split(model_str, "/", parts: 2) do
      [provider, model] ->
        {provider, model}

      [bare_model] ->
        provider = infer_provider(bare_model) || fallback_provider || "anthropic"
        {provider, bare_model}
    end
  end

  defp infer_provider(model_name) do
    @model_prefixes
    |> Enum.find_value(fn {prefix, provider} ->
      if String.starts_with?(model_name, prefix), do: provider
    end)
  end

  # --- Model listing ---

  defp get_cached_models(%ProviderConfig{models: models}) when is_list(models) do
    {:ok, models}
  end

  defp get_cached_models(%ProviderConfig{models: :auto, model_cache: cache})
       when is_list(cache) do
    {:ok, cache}
  end

  defp get_cached_models(%ProviderConfig{models: :auto, module: module} = config) do
    Code.ensure_loaded(module)

    if function_exported?(module, :list_models, 1) do
      opts = [api_key: config.api_key] |> maybe_opt(:base_url, config.base_url)

      case module.list_models(opts) do
        {:ok, models} ->
          {:ok, models}

        {:error, reason} ->
          Logger.warning("Failed to list models for #{config.name}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:ok, []}
    end
  end

  defp get_cached_models(_), do: {:ok, []}

  # --- Helpers ---

  defp provider_api_type(Egghead.LLM.Anthropic), do: "anthropic"
  defp provider_api_type(Egghead.LLM.OpenAI), do: "openai"
  defp provider_api_type(Egghead.LLM.Google), do: "google"
  defp provider_api_type(_), do: "unknown"

  defp maybe_opt(opts, _key, nil), do: opts
  defp maybe_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp legacy_user_config_path do
    Path.join(System.user_home!(), ".egghead/providers.yml")
  end
end
