defmodule Egghead.Config do
  @moduledoc """
  Configuration for Egghead.

  Loads from `~/.config/egghead/config.yml` (respects `$XDG_CONFIG_HOME`).
  Pure file I/O — no GenServer — so it can be called from `runtime.exs`
  before the application starts.

  ## Precedence

  1. Environment variables (highest — `ANTHROPIC_API_KEY`, `PORT`, etc.)
  2. Config file (`~/.config/egghead/config.yml`)
  3. Defaults

  ## Config file format

      records_dir: ~/.egghead

      llm:
        - provider: anthropic
          api_key: sk-ant-...
        - provider: openai
          api_key: "{env:OPENAI_API_KEY}"

      default_model: anthropic/claude-sonnet-4-6

      web:
        port: 4000
        host: localhost
        bind: 127.0.0.1
  """

  defstruct records_dir: "~/.egghead",
            skills_dir: "~/.agents/skills",
            llm: [],
            default_model: nil,
            web: %{port: 4000, host: "localhost", bind: "127.0.0.1"}

  @type llm_entry :: %{
          provider: String.t(),
          api_key: String.t() | nil,
          base_url: String.t() | nil,
          name: String.t() | nil
        }

  @type t :: %__MODULE__{
          records_dir: String.t(),
          skills_dir: String.t(),
          llm: [llm_entry()],
          default_model: String.t() | nil,
          web: %{port: non_neg_integer(), host: String.t(), bind: String.t()}
        }

  # --- Paths ---

  @doc """
  Config directory, respecting `$EGGHEAD_CONFIG` and `$XDG_CONFIG_HOME`.

  If `$EGGHEAD_CONFIG` is set to a file path, returns its directory.
  If `$EGGHEAD_CONFIG` is set to a directory, returns it directly.
  Otherwise uses `$XDG_CONFIG_HOME/egghead` (default `~/.config/egghead`).
  """
  def config_dir do
    case System.get_env("EGGHEAD_CONFIG") do
      nil ->
        xdg = System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")
        Path.join(xdg, "egghead")

      path ->
        if String.ends_with?(path, ".yml") or String.ends_with?(path, ".yaml"),
          do: Path.dirname(path),
          else: path
    end
  end

  @doc """
  Full path to `config.yml`.

  Respects `$EGGHEAD_CONFIG` — if set to a `.yml` file, uses that
  path directly. Otherwise appends `config.yml` to the config dir.
  """
  def config_path do
    case System.get_env("EGGHEAD_CONFIG") do
      nil ->
        Path.join(config_dir(), "config.yml")

      path ->
        if String.ends_with?(path, ".yml") or String.ends_with?(path, ".yaml"),
          do: path,
          else: Path.join(path, "config.yml")
    end
  end

  @doc "Whether the config file exists on disk."
  def exists?, do: File.exists?(config_path())

  @doc """
  Log file path, following XDG Base Directory spec.

  Defaults to `$XDG_STATE_HOME/egghead/egghead.log`
  (typically `~/.local/state/egghead/egghead.log`).
  """
  def log_path do
    state_dir =
      System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")

    Path.join([state_dir, "egghead", "egghead.log"])
  end

  # --- Loading ---

  @doc """
  Loads configuration from disk.

  Returns `{:ok, %Config{}}` if a config file exists and parses,
  `{:error, :not_found}` if no config file, or
  `{:error, {:invalid, reason}}` if the file is malformed.
  """
  @spec load() :: {:ok, t()} | {:error, :not_found | {:invalid, term()}}
  def load do
    path = config_path()

    case File.read(path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, data} when is_map(data) ->
            {:ok, from_map(data)}

          {:ok, _} ->
            {:error, {:invalid, :not_a_map}}

          {:error, reason} ->
            {:error, {:invalid, reason}}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:invalid, reason}}
    end
  end

  @doc "Like `load/0` but raises on error."
  @spec load!() :: t()
  def load! do
    case load() do
      {:ok, config} -> config
      {:error, :not_found} -> raise "Config file not found: #{config_path()}"
      {:error, {:invalid, reason}} -> raise "Invalid config: #{inspect(reason)}"
    end
  end

  # --- Saving ---

  @doc """
  Writes a `%Config{}` to disk as YAML. Creates the config directory
  if needed and sets file permissions to `0600`.
  """
  @spec save(t()) :: :ok | {:error, term()}
  def save(%__MODULE__{} = config) do
    path = config_path()
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         yaml = to_yaml(config),
         :ok <- File.write(path, yaml),
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  end

  # --- Accessors ---

  @doc "Expanded records directory path."
  def records_dir(%__MODULE__{records_dir: dir}), do: Path.expand(dir)

  @doc "Expanded skills directory path (the SKILLS_DIR drop zone)."
  def skills_dir(%__MODULE__{skills_dir: dir}), do: Path.expand(dir)

  @doc "Web port."
  def port(%__MODULE__{web: %{port: port}}), do: port

  @doc "Web host."
  def host(%__MODULE__{web: %{host: host}}), do: host

  @doc "Web bind address as a tuple."
  def bind(%__MODULE__{web: %{bind: bind}}) do
    case bind do
      "0.0.0.0" -> {0, 0, 0, 0}
      _ -> {127, 0, 0, 1}
    end
  end

  # --- Value resolution ---

  @doc """
  Resolves `{env:VAR_NAME}` patterns to their environment variable values.
  Returns the value unchanged if it doesn't match the pattern.
  """
  @spec resolve_value(term()) :: term()
  def resolve_value(nil), do: nil

  def resolve_value(value) when is_binary(value) do
    case Regex.run(~r/^\{env:(\w+)\}$/, value) do
      [_, var_name] -> System.get_env(var_name)
      _ -> value
    end
  end

  def resolve_value(value), do: value

  # --- Dot-path access ---

  @doc "Get a value by dot-path string (e.g. `\"web.port\"`)."
  @spec get(t(), String.t()) :: term()
  def get(%__MODULE__{} = config, path) when is_binary(path) do
    keys = String.split(path, ".")
    get_in_config(Map.from_struct(config), keys)
  end

  @doc "Set a value by dot-path and save to disk."
  @spec set(String.t(), String.t()) :: :ok | {:error, term()}
  def set(path, value) do
    case load() do
      {:ok, config} ->
        updated = set_in_config(config, String.split(path, "."), cast_value(value))
        save(updated)

      {:error, :not_found} ->
        config = set_in_config(%__MODULE__{}, String.split(path, "."), cast_value(value))
        save(config)

      {:error, _} = err ->
        err
    end
  end

  # --- Private: YAML parsing ---

  defp from_map(data) do
    %__MODULE__{
      records_dir: data["records_dir"] || "~/.egghead",
      skills_dir: data["skills_dir"] || "~/.agents/skills",
      llm: parse_llm(data["llm"]),
      default_model: data["default_model"],
      web: parse_web(data["web"])
    }
  end

  defp parse_llm(nil), do: []
  defp parse_llm(entries) when is_list(entries), do: Enum.map(entries, &parse_llm_entry/1)
  defp parse_llm(entries) when is_map(entries), do: parse_llm_legacy(entries)
  defp parse_llm(_), do: []

  defp parse_llm_entry(entry) when is_map(entry) do
    %{
      provider: entry["provider"] || "custom",
      api_key: recover_env_ref(entry["api_key"]),
      base_url: entry["base_url"],
      name: entry["name"]
    }
  end

  defp parse_llm_entry(_), do: nil

  # Support legacy providers.yml format embedded in config
  defp parse_llm_legacy(providers_map) do
    Enum.map(providers_map, fn {name, config} ->
      %{
        provider: name,
        api_key: config["api_key"],
        base_url: config["base_url"],
        name: nil
      }
    end)
  end

  defp parse_web(nil), do: %{port: 4000, host: "localhost", bind: "127.0.0.1"}

  defp parse_web(web) when is_map(web) do
    %{
      port: web["port"] || 4000,
      host: web["host"] || "localhost",
      bind: web["bind"] || "127.0.0.1"
    }
  end

  defp parse_web(_), do: %{port: 4000, host: "localhost", bind: "127.0.0.1"}

  # --- Private: YAML emitting ---

  defp to_yaml(%__MODULE__{} = config) do
    sections = [
      emit_field("records_dir", config.records_dir),
      emit_field("skills_dir", config.skills_dir),
      emit_llm(config.llm),
      emit_field("default_model", config.default_model),
      emit_web(config.web)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp emit_field(_key, nil), do: nil
  defp emit_field(key, value), do: "#{key}: #{yaml_escape(value)}"

  defp emit_llm([]), do: nil

  defp emit_llm(entries) do
    items =
      Enum.map_join(entries, "\n", fn entry ->
        lines = ["  - provider: #{entry.provider}"]

        lines =
          if entry[:name],
            do: lines ++ ["    name: #{entry.name}"],
            else: lines

        lines =
          if entry[:api_key],
            do: lines ++ ["    api_key: #{yaml_escape(entry.api_key)}"],
            else: lines

        lines =
          if entry[:base_url],
            do: lines ++ ["    base_url: #{yaml_escape(entry.base_url)}"],
            else: lines

        Enum.join(lines, "\n")
      end)

    "llm:\n#{items}"
  end

  defp emit_web(%{port: 4000, host: "localhost", bind: "127.0.0.1"}), do: nil

  defp emit_web(web) do
    lines = ["web:"]
    lines = if web.port != 4000, do: lines ++ ["  port: #{web.port}"], else: lines
    lines = if web.host != "localhost", do: lines ++ ["  host: #{web.host}"], else: lines
    lines = if web.bind != "127.0.0.1", do: lines ++ ["  bind: #{web.bind}"], else: lines

    if length(lines) > 1, do: Enum.join(lines, "\n"), else: nil
  end

  # If YAML parsed {env:VAR} as a map %{"env:VAR" => nil}, recover the string form
  defp recover_env_ref(value) when is_map(value) do
    case Map.keys(value) do
      [key] when is_binary(key) ->
        if String.starts_with?(key, "env:"), do: "{#{key}}", else: value

      _ ->
        value
    end
  end

  defp recover_env_ref(value), do: value

  # --- Private: YAML value escaping ---

  # Values containing YAML-special characters need quoting
  defp yaml_escape(value) when is_binary(value) do
    if String.contains?(value, ["{", "}", ":", "#", "[", "]", ",", "&", "*", "?", "|", "'", "\""]) do
      ~s("#{String.replace(value, "\"", "\\\"")}")
    else
      value
    end
  end

  defp yaml_escape(value), do: to_string(value)

  # --- Private: dot-path helpers ---

  defp get_in_config(data, [key]) when is_map(data),
    do: Map.get(data, String.to_existing_atom(key))

  defp get_in_config(data, [key | rest]) when is_map(data) do
    case Map.get(data, String.to_existing_atom(key)) do
      nested when is_map(nested) -> get_in_config(nested, rest)
      _ -> nil
    end
  end

  defp get_in_config(_, _), do: nil

  defp set_in_config(%__MODULE__{} = config, [key | rest], value) do
    atom_key = String.to_existing_atom(key)
    current = Map.get(config, atom_key)

    new_value =
      case {rest, current} do
        {[], _} -> value
        {_, nested} when is_map(nested) -> set_in_map(nested, rest, value)
        _ -> value
      end

    Map.put(config, atom_key, new_value)
  end

  defp set_in_map(map, [key], value), do: Map.put(map, String.to_atom(key), value)

  defp set_in_map(map, [key | rest], value) do
    atom_key = String.to_atom(key)
    nested = Map.get(map, atom_key, %{})
    Map.put(map, atom_key, set_in_map(nested, rest, value))
  end

  defp cast_value(value) do
    cond do
      value =~ ~r/^\d+$/ -> String.to_integer(value)
      value == "true" -> true
      value == "false" -> false
      true -> value
    end
  end
end
