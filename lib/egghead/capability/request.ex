defmodule Egghead.Capability.Request do
  @moduledoc """
  A capability request built by a tool at dispatch time. Described what
  the agent is about to do (resource, verb, parameters), checked against
  the agent's held `Grant`s by `Egghead.Capability.check/3`.
  """

  @type t :: %__MODULE__{
          resource: atom(),
          verb: atom(),
          scope: map(),
          tool: String.t() | nil
        }

  defstruct [:resource, :verb, :tool, scope: %{}]

  @spec key(t()) :: String.t()
  def key(%__MODULE__{resource: r, verb: v}), do: "#{r}.#{v}"
end
