defmodule Egghead.LLM.Provider do
  @moduledoc """
  Behaviour for LLM providers.

  Providers handle the actual API communication with an LLM service.
  Each provider implements a single callback: `chat/2`, which sends
  messages and returns a response.
  """

  @type message :: %{role: String.t(), content: String.t()}
  @type opts :: keyword()
  @type token_usage :: keyword()
  @type response :: {:ok, String.t(), token_usage()} | {:error, term()}

  @doc """
  Sends a list of messages to the LLM and returns the response text.

  ## Options

    * `:model` — model identifier (provider-specific)
    * `:max_tokens` — maximum response tokens
    * `:temperature` — sampling temperature
    * `:system` — system prompt
  """
  @callback chat(messages :: [message()], opts :: opts()) :: response()
  @optional_callbacks [chat: 2]
end
