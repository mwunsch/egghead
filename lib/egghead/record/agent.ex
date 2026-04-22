defmodule Egghead.Record.Agent do
  @moduledoc """
  Projection of an `:agent`-class record into the typed configuration
  an Agent GenServer consumes.

  Records are free-form: any meta key is permitted and most are
  optional. `from/1` always succeeds and fills defaults — the system
  never refuses to load an agent record just because a field is
  missing. An agent record with no `capabilities:` and no `access:`
  key defaults to `records.read` so it can at least inspect the
  graph; a more restricted agent requires explicit (empty) frontmatter.

  The `access:` frontmatter key is a chmod-flavored shortcut for
  common records-capability bundles. See `expand_access/1`.

  Mirrors `Egghead.Skill`'s role for `:skill`-class records: a single
  place that knows which meta keys a class cares about, how to read
  them, and what to do when they're absent.
  """

  require Logger

  alias Egghead.Capability
  alias Egghead.LLM.Registry
  alias Egghead.Record

  @default_context_threshold 0.70
  @default_max_tokens 4096
  @fallback_model "anthropic/claude-sonnet-4-6"

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          disposition: String.t(),
          model: String.t(),
          provider: String.t() | nil,
          capabilities: [Capability.t()],
          tags: [String.t()],
          thinking: String.t() | nil,
          max_tokens: pos_integer(),
          temperature: float() | nil,
          context_threshold: float(),
          context_window: pos_integer() | nil
        }

  defstruct [
    :id,
    :name,
    :disposition,
    :model,
    :provider,
    :thinking,
    :temperature,
    :context_window,
    capabilities: [],
    tags: [],
    max_tokens: @default_max_tokens,
    context_threshold: @default_context_threshold
  ]

  @doc """
  Project an agent record into typed config. Always succeeds; fills
  defaults for any absent meta key.
  """
  @spec from(Record.t()) :: t()
  def from(%Record{} = record) do
    %__MODULE__{
      id: record.id,
      name: record.title || record.id,
      disposition: record.body || "",
      model: resolve_model(record),
      provider: meta_string(record, "provider"),
      capabilities: parse_capabilities(record),
      tags: Enum.reject(record.tags || [], &(&1 == "agent")),
      thinking: meta_string(record, "thinking"),
      max_tokens: meta_int(record, "max_tokens", @default_max_tokens),
      temperature: meta_float(record, "temperature", nil),
      context_threshold: meta_float(record, "context_threshold", @default_context_threshold),
      context_window: meta_int(record, "context_window", nil)
    }
  end

  @doc """
  Parse the `capabilities` and `access` meta keys into a merged
  capability list.

  Rules:

  - If **neither** key is present, default to `records.read` (useful
    by default — the human-edits-frontmatter-to-restrict principle).
  - If **either** is present, expand `access:` and union with the
    explicit `capabilities:` list. No default is applied — if you
    wrote `capabilities: []` you get zero grants.
  - Duplicates are merged by `Capability.parse/1`.
  """
  @spec parse_capabilities(Record.t()) :: [Capability.t()]
  def parse_capabilities(%Record{meta: meta}) do
    has_access? = Map.has_key?(meta, "access")
    has_caps? = Map.has_key?(meta, "capabilities")

    if not has_access? and not has_caps? do
      Capability.parse(["records.read"])
    else
      Capability.parse(expand_access(meta["access"]) ++ normalize_caps(meta["capabilities"]))
    end
  end

  @doc """
  Expand the `access:` shortcut into capability strings.

  - `"r"` → `["records.read"]`
  - `"w"` → `["records.create", "records.update"]`
  - `"rw"` → `["records.read", "records.create", "records.update"]`

  `nil` returns `[]`. Any other value logs a warning and returns `[]`
  (consistent with `Capability.parse/1`'s lenient unknown-entry
  handling). Strict validation for user input lives in
  `Egghead.Agent.Wizard` and `Egghead.Agent.Tools`.

  Note: `records.delete` is deliberately excluded from the shortcut.
  High-risk verbs require an explicit `capabilities:` entry.
  """
  @spec expand_access(term()) :: [String.t()]
  def expand_access(nil), do: []

  def expand_access(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "r" ->
        ["records.read"]

      "w" ->
        ["records.create", "records.update"]

      "rw" ->
        ["records.read", "records.create", "records.update"]

      "" ->
        []

      other ->
        Logger.warning(
          "Record.Agent: unknown access mode #{inspect(other)} — expected 'r', 'w', or 'rw'"
        )

        []
    end
  end

  def expand_access(other) do
    Logger.warning("Record.Agent: access must be a string — got #{inspect(other)}")
    []
  end

  @doc """
  True if `value` is a valid `access:` mode (`"r"`, `"w"`, `"rw"`).
  Used by the wizard and tool layers for strict validation.
  """
  @spec valid_access?(term()) :: boolean()
  def valid_access?(value) when is_binary(value) do
    String.downcase(String.trim(value)) in ~w(r w rw)
  end

  def valid_access?(_), do: false

  defp normalize_caps(nil), do: []
  defp normalize_caps(list) when is_list(list), do: list
  defp normalize_caps(str) when is_binary(str), do: String.split(str, ~r/[,\s]+/, trim: true)
  defp normalize_caps(_), do: []

  # --- Helpers ---

  defp resolve_model(%Record{meta: meta}) do
    raw = meta_string_value(meta["model"])
    provider = meta_string_value(meta["provider"])

    cond do
      raw && String.contains?(raw, "/") -> raw
      raw && provider -> "#{provider}/#{raw}"
      raw -> raw
      true -> default_model()
    end
  end

  defp default_model do
    try do
      Registry.default_model()
    catch
      :exit, _ -> @fallback_model
    end
  end

  defp meta_string(%Record{meta: meta}, key, default \\ nil) do
    case meta[key] do
      nil -> default
      val -> to_string(val)
    end
  end

  defp meta_string_value(nil), do: nil
  defp meta_string_value(val), do: to_string(val)

  defp meta_int(%Record{meta: meta}, key, default) do
    case meta[key] do
      nil -> default
      val when is_integer(val) -> val
      val -> String.to_integer(to_string(val))
    end
  rescue
    _ -> default
  end

  defp meta_float(%Record{meta: meta}, key, default) do
    case meta[key] do
      nil -> default
      val when is_float(val) -> val
      val when is_integer(val) -> val / 1
      val -> String.to_float(to_string(val))
    end
  rescue
    _ -> default
  end
end
