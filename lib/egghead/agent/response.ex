defmodule Egghead.Agent.Response do
  @moduledoc """
  Structured response from an agent prompt.

  Contains the response text, token usage, tool call log, records
  touched, model info, and timing.
  """

  @type tool_call :: %{
          name: String.t(),
          input: map(),
          result: String.t(),
          error: boolean()
        }

  @type t :: %__MODULE__{
          text: String.t(),
          agent_id: String.t(),
          model: String.t(),
          usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()},
          tool_calls: [tool_call()],
          records_created: [String.t()],
          records_updated: [String.t()],
          duration_ms: non_neg_integer()
        }

  defstruct [
    :text,
    :agent_id,
    :model,
    usage: %{input_tokens: 0, output_tokens: 0},
    tool_calls: [],
    records_created: [],
    records_updated: [],
    duration_ms: 0
  ]
end
