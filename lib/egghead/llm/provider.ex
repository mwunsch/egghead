defmodule Egghead.LLM.Provider do
  @moduledoc """
  Behaviour for LLM providers.

  Each provider module implements communication with a specific LLM API
  (Anthropic, OpenAI, Google, or OpenAI-compatible). The Registry resolves
  `provider/model` strings to the right module and config.
  """

  @type message :: %{role: String.t(), content: term()}
  @type opts :: keyword()
  @type token_usage :: keyword()

  @doc """
  Sends messages to the LLM. Returns `{:ok, response_map}` or `{:error, reason}`.

  The response map contains `:content` (list of content blocks), `:stop_reason`,
  and `:usage` (keyword list with `:input_tokens` and `:output_tokens`).
  """
  @callback chat(messages :: [message()], opts :: opts()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Streaming chat. Same as `chat/2` but calls `opts[:on_chunk]` with deltas.
  """
  @callback chat_stream(messages :: [message()], opts :: opts()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Fetches metadata for a specific model (context window, capabilities).
  """
  @callback get_model_info(model_id :: String.t(), opts :: opts()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Lists available models from the provider.
  """
  @callback list_models(opts :: opts()) ::
              {:ok, [map()]} | {:error, term()}

  @optional_callbacks [chat_stream: 2, list_models: 1, get_model_info: 2]
end
