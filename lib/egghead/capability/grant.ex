defmodule Egghead.Capability.Grant do
  @moduledoc """
  A single capability held by an agent. The authoritative shape of
  authority: a resource, a verb on that resource, and an optional scope
  (the Capsicum influence — rights narrow by parameters).

  Parsed from frontmatter by `Egghead.Capability.parse/1`.
  """

  @type resource :: :records | :fs | :net | :shell | :search
  @type verb :: atom()
  @type scope :: map()

  @type t :: %__MODULE__{
          resource: resource(),
          verb: verb(),
          scope: scope()
        }

  defstruct [:resource, :verb, scope: %{}]

  @doc "Resource.verb key used for quick lookup — e.g. `\"net.get\"`."
  @spec key(t()) :: String.t()
  def key(%__MODULE__{resource: r, verb: v}), do: "#{r}.#{v}"
end
