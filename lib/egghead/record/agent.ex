defmodule Egghead.Record.Agent do
  @moduledoc """
  Projection of an `:agent`-class record into the typed configuration
  an Agent GenServer consumes.

  Records are free-form: any meta key is permitted and most are
  optional. `from/1` always succeeds and fills defaults — the system
  never refuses to load an agent record just because a field is
  missing. A record with no `capabilities:` is still a valid agent;
  it just can't do much.

  Mirrors `Egghead.Skill`'s role for `:skill`-class records: a single
  place that knows which meta keys a class cares about, how to read
  them, and what to do when they're absent.
  """

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
          context_threshold: float()
        }

  defstruct [
    :id,
    :name,
    :disposition,
    :model,
    :provider,
    :thinking,
    :temperature,
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
      context_threshold: meta_float(record, "context_threshold", @default_context_threshold)
    }
  end

  @doc "Parse the `capabilities` meta key into a capability list."
  @spec parse_capabilities(Record.t()) :: [Capability.t()]
  def parse_capabilities(%Record{meta: meta}) do
    case meta["capabilities"] do
      nil -> Capability.parse(["records.read"])
      value -> Capability.parse(value)
    end
  end

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
