defmodule Egghead.Capability.Denial do
  @moduledoc """
  A capability check failure, carrying everything the UI, the LLM, and the
  audit log each need. Three destinations, one struct.
  """

  alias Egghead.Capability.Grant
  alias Egghead.Capability.Request

  @type code ::
          :capability_absent
          | :scope_violation
          | :self_modification
          | :unknown_tool

  @type t :: %__MODULE__{
          code: code(),
          request: Request.t() | nil,
          held: [Grant.t()],
          agent_id: String.t() | nil,
          tool: String.t() | nil,
          message: String.t(),
          suggested_grant: String.t() | nil
        }

  defstruct [
    :code,
    :request,
    :agent_id,
    :tool,
    :message,
    :suggested_grant,
    held: []
  ]

  @doc """
  Formats the denial for display to the LLM as a tool_result body.
  Structured, actionable, includes a suggested grant so the model can
  escalate to the human clearly.
  """
  @spec to_tool_result(t()) :: String.t()
  def to_tool_result(%__MODULE__{} = d) do
    lines = [
      "Denied: #{d.tool || "tool call"}.",
      "  Reason: #{d.code}",
      "  #{d.message}"
    ]

    lines =
      if d.suggested_grant do
        lines ++
          [
            "  To enable, ask the human to run:",
            "    egghead agent grant #{d.agent_id} '#{d.suggested_grant}'"
          ]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  @doc "Structured metadata for Logger."
  @spec to_log_metadata(t()) :: keyword()
  def to_log_metadata(%__MODULE__{} = d) do
    [
      capability_denial: d.code,
      agent_id: d.agent_id,
      tool: d.tool,
      resource: d.request && d.request.resource,
      verb: d.request && d.request.verb,
      scope: d.request && d.request.scope
    ]
  end
end
