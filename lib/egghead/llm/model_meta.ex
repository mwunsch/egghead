defmodule Egghead.LLM.ModelMeta do
  @moduledoc false

  # Cross-provider model metadata lookup, keyed on model-id prefix.
  #
  # Used as a fallback when a provider API doesn't expose context-window
  # info (OpenAI's `/v1/models` returns only `{id, created, object,
  # owned_by}`; xAI, DeepSeek, Mistral behave similarly over their
  # OpenAI-compat endpoints). Anthropic and Gemini expose these natively
  # via their models APIs — the entries below are safety nets in case the
  # probe fails (no network, rate limit, registry unavailable).
  #
  # Update as providers ship new families. A missing entry returns `nil`
  # so the agent/TUI can render an honest "unknown" rather than a lie.

  @doc """
  Returns `{context_window, max_output}` for a model id, falling back to
  `nil` for each unknown field. Pattern-matches on family prefix.

  ## Examples

      iex> Egghead.LLM.ModelMeta.lookup("gpt-5.4")
      {400_000, 128_000}

      iex> Egghead.LLM.ModelMeta.lookup("grok-4-1")
      {256_000, 16_384}

      iex> Egghead.LLM.ModelMeta.lookup("completely-unknown")
      {nil, nil}
  """
  @spec lookup(String.t() | nil) :: {pos_integer() | nil, pos_integer() | nil}
  def lookup(model_id) when is_binary(model_id) do
    {context_window(model_id), max_output(model_id)}
  end

  def lookup(_), do: {nil, nil}

  @doc "Returns the known context window for a model id, or `nil`."
  @spec context_window(String.t() | nil) :: pos_integer() | nil
  def context_window(id) when is_binary(id) do
    cond do
      # --- Anthropic (Claude 3.x, 4.x) — /v1/models exposes this natively ---
      String.starts_with?(id, "claude-") -> 200_000
      # --- OpenAI ---
      String.starts_with?(id, "gpt-5") -> 400_000
      String.starts_with?(id, "gpt-4.1") -> 1_047_576
      String.starts_with?(id, "chatgpt-4o") -> 128_000
      String.starts_with?(id, "gpt-4o") -> 128_000
      String.starts_with?(id, "gpt-4-turbo") -> 128_000
      String.starts_with?(id, "gpt-4-32k") -> 32_768
      String.contains?(id, "gpt-4-0125") -> 128_000
      String.contains?(id, "gpt-4-1106") -> 128_000
      String.starts_with?(id, "gpt-4") -> 8_192
      String.starts_with?(id, "gpt-3.5") -> 16_385
      String.starts_with?(id, "o1-preview") -> 128_000
      String.starts_with?(id, "o1-mini") -> 128_000
      String.starts_with?(id, "o1") -> 200_000
      String.starts_with?(id, "o3-mini") -> 200_000
      String.starts_with?(id, "o3") -> 200_000
      String.starts_with?(id, "o4-mini") -> 200_000
      String.starts_with?(id, "o4") -> 200_000
      String.starts_with?(id, "o5") -> 200_000
      # --- Google Gemini — /v1beta/models exposes this natively ---
      String.starts_with?(id, "gemini-1.5-pro") -> 2_097_152
      String.starts_with?(id, "gemini-1.5") -> 1_048_576
      String.starts_with?(id, "gemini-2.0") -> 1_048_576
      String.starts_with?(id, "gemini-2.5") -> 1_048_576
      String.starts_with?(id, "gemini") -> 1_048_576
      # --- xAI Grok ---
      String.starts_with?(id, "grok-4") -> 256_000
      String.starts_with?(id, "grok-3") -> 131_072
      String.starts_with?(id, "grok-2") -> 131_072
      String.starts_with?(id, "grok") -> 131_072
      # --- DeepSeek ---
      String.starts_with?(id, "deepseek-v4") -> 1_000_000
      String.starts_with?(id, "deepseek") -> 128_000
      # --- Mistral ---
      String.starts_with?(id, "mistral-large") -> 128_000
      String.starts_with?(id, "mistral-medium") -> 128_000
      String.starts_with?(id, "mistral-small") -> 128_000
      String.starts_with?(id, "mistral-nemo") -> 128_000
      String.starts_with?(id, "mistral") -> 32_768
      String.starts_with?(id, "codestral") -> 32_768
      String.starts_with?(id, "ministral") -> 128_000
      String.starts_with?(id, "pixtral") -> 128_000
      # --- Meta Llama ---
      String.starts_with?(id, "llama-3.3") -> 128_000
      String.starts_with?(id, "llama-3.2") -> 128_000
      String.starts_with?(id, "llama-3.1") -> 128_000
      String.starts_with?(id, "llama-3") -> 8_192
      String.starts_with?(id, "llama") -> 8_192
      true -> nil
    end
  end

  def context_window(_), do: nil

  @doc "Returns the known max output-token ceiling for a model id, or `nil`."
  @spec max_output(String.t() | nil) :: pos_integer() | nil
  def max_output(id) when is_binary(id) do
    cond do
      # Anthropic
      String.starts_with?(id, "claude-opus") -> 32_000
      String.starts_with?(id, "claude-sonnet") -> 64_000
      String.starts_with?(id, "claude-haiku") -> 8_192
      String.starts_with?(id, "claude") -> 8_192
      # OpenAI
      String.starts_with?(id, "gpt-5") -> 128_000
      String.starts_with?(id, "gpt-4.1") -> 32_768
      String.starts_with?(id, "gpt-4o") -> 16_384
      String.starts_with?(id, "chatgpt-4o") -> 16_384
      String.starts_with?(id, "gpt-4-turbo") -> 4_096
      String.starts_with?(id, "gpt-4-32k") -> 4_096
      String.starts_with?(id, "gpt-4") -> 8_192
      String.starts_with?(id, "gpt-3.5") -> 4_096
      String.starts_with?(id, "o1-mini") -> 65_536
      String.starts_with?(id, "o1-preview") -> 32_768
      String.starts_with?(id, "o1") -> 100_000
      String.starts_with?(id, "o3") -> 100_000
      String.starts_with?(id, "o4") -> 100_000
      String.starts_with?(id, "o5") -> 100_000
      # Google Gemini
      String.starts_with?(id, "gemini-2.5") -> 65_536
      String.starts_with?(id, "gemini-2.0") -> 8_192
      String.starts_with?(id, "gemini-1.5") -> 8_192
      String.starts_with?(id, "gemini") -> 8_192
      # xAI
      String.starts_with?(id, "grok") -> 16_384
      # DeepSeek
      String.starts_with?(id, "deepseek") -> 8_192
      # Mistral
      String.starts_with?(id, "mistral") -> 8_192
      String.starts_with?(id, "codestral") -> 8_192
      String.starts_with?(id, "ministral") -> 8_192
      String.starts_with?(id, "pixtral") -> 8_192
      # Llama
      String.starts_with?(id, "llama") -> 8_192
      true -> nil
    end
  end

  def max_output(_), do: nil
end
