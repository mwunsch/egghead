defmodule Egghead.Eval.CapabilityCheck do
  @moduledoc """
  Union-of-roster capability gating for eval tasks.

  A task is runnable iff the union of capabilities across all agents
  in the roster covers the task's required capabilities. No single
  agent needs to hold every required verb — collaboration across
  role-specialised agents is the point.

  Required capabilities are expressed as `"resource.verb"` strings
  in task frontmatter (`required_capabilities`). Roster capabilities
  are read from each agent's `capabilities` meta field.
  """

  alias Egghead.Eval.Task

  @doc """
  Checks a roster (a list of `Egghead.Record{class: :agent}`) against
  a task's required capabilities. Returns `:ok` if the union covers
  the requirements, or `{:error, {:missing, [verb()]}}` with the
  unmet verbs.
  """
  @spec check(Task.t(), [Egghead.Record.t()]) ::
          :ok | {:error, {:missing, [String.t()]}}
  def check(%Task{required_capabilities: []}, _roster), do: :ok

  def check(%Task{required_capabilities: required}, roster) do
    held =
      roster
      |> Enum.flat_map(&agent_capabilities/1)
      |> MapSet.new()

    missing =
      required
      |> Enum.reject(&MapSet.member?(held, &1))

    case missing do
      [] -> :ok
      _ -> {:error, {:missing, missing}}
    end
  end

  defp agent_capabilities(%Egghead.Record{meta: meta}) when is_map(meta) do
    meta
    |> Map.get("capabilities", [])
    |> List.wrap()
    |> Enum.flat_map(&verb_of/1)
  end

  defp agent_capabilities(_), do: []

  # Capability entries can be either bare verb strings (`"records.read"`)
  # or scoped maps (`%{"net.get" => %{"hosts" => ["*"]}}`). For gating
  # we only need the verb; scope is enforced at dispatch time, not here.
  defp verb_of(string) when is_binary(string), do: [string]
  defp verb_of(atom) when is_atom(atom), do: [Atom.to_string(atom)]

  defp verb_of(%{} = map) do
    map
    |> Map.keys()
    |> Enum.map(&to_string/1)
  end

  defp verb_of(_), do: []

  @doc """
  Formats a missing-capabilities error for human consumption.
  """
  @spec format_error({:missing, [String.t()]}, [Egghead.Record.t()]) :: String.t()
  def format_error({:missing, missing}, roster) do
    held =
      roster
      |> Enum.map(fn record ->
        caps = agent_capabilities(record)
        "    #{record.id}: #{Enum.join(caps, ", ")}"
      end)
      |> Enum.join("\n")

    """
    Required capabilities not covered by roster.
    Missing: #{Enum.join(missing, ", ")}
    Roster capabilities:
    #{held}
    """
  end
end
