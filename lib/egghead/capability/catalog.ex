defmodule Egghead.Capability.Catalog do
  @moduledoc """
  Human-facing documentation for each capability. Used by the agent
  creation wizard, denial renderer, and `egghead agent capabilities` CLI
  to display capabilities as readable labels rather than opaque
  `resource.verb` strings.

  Entries are keyed by `{resource, verb}`. Each entry carries a short
  label and a risk level that drives UI ordering/styling (low → high).
  """

  alias Egghead.Capability.Grant

  @type risk :: :low | :medium | :high
  @type entry :: %{short: String.t(), risk: risk()}

  @catalog %{
    # Content records
    {:records, :read} => %{short: "Read and search records", risk: :low},
    {:records, :create} => %{short: "Create new content records", risk: :low},
    {:records, :update} => %{short: "Edit existing content records", risk: :medium},
    {:records, :delete} => %{short: "Delete content records", risk: :high},

    # Agents — the authority-bearing operations
    {:agent, :create} => %{
      short: "Create new agents (inert capabilities until granted)",
      risk: :medium
    },
    {:agent, :update} => %{
      short: "Edit agent disposition, model, tags (not capabilities)",
      risk: :medium
    },
    {:agent, :delete} => %{short: "Remove agents", risk: :high},
    {:agent, :grant} => %{
      short: "Grant capabilities to agents (attenuation-bound)",
      risk: :high
    },

    # Filesystem outside the record store
    {:fs, :read} => %{short: "Read files outside the record store", risk: :medium},
    {:fs, :write} => %{short: "Write files outside the record store", risk: :high},
    {:fs, :delete} => %{short: "Delete files outside the record store", risk: :high},

    # Network — HTTP verbs
    {:net, :get} => %{short: "Fetch web pages (HTTP GET)", risk: :medium},
    {:net, :post} => %{short: "Submit data to web APIs (HTTP POST)", risk: :high},
    {:net, :put} => %{short: "Update remote resources (HTTP PUT)", risk: :high},
    {:net, :delete} => %{short: "Delete remote resources (HTTP DELETE)", risk: :high},

    # Shell
    {:shell, :exec} => %{short: "Run allow-listed shell commands", risk: :high}
  }

  @risk_order %{low: 0, medium: 1, high: 2}

  @doc "All catalog entries as a list of {resource, verb, entry} tuples."
  @spec all() :: [{atom(), atom(), entry()}]
  def all do
    Enum.map(@catalog, fn {{r, v}, e} -> {r, v, e} end)
  end

  @doc "Look up catalog metadata for a resource/verb. Returns `nil` if unknown."
  @spec lookup(atom(), atom()) :: entry() | nil
  def lookup(resource, verb), do: Map.get(@catalog, {resource, verb})

  @doc "Short label for a grant, with scope rendered inline if present."
  @spec describe(Grant.t()) :: String.t()
  def describe(%Grant{resource: r, verb: v, scope: scope}) do
    base =
      case lookup(r, v) do
        %{short: short} -> short
        nil -> "#{r}.#{v}"
      end

    case render_scope(r, scope) do
      nil -> base
      extra -> "#{base} — #{extra}"
    end
  end

  @doc "Risk level for a grant (defaults to `:medium` if unknown)."
  @spec risk(Grant.t()) :: risk()
  def risk(%Grant{resource: r, verb: v}) do
    case lookup(r, v) do
      %{risk: risk} -> risk
      nil -> :medium
    end
  end

  @doc "Sort a list of grants by risk ascending, then by resource/verb."
  @spec sort_by_risk([Grant.t()]) :: [Grant.t()]
  def sort_by_risk(grants) do
    Enum.sort_by(grants, fn %Grant{resource: r, verb: v} = g ->
      {Map.get(@risk_order, risk(g), 1), "#{r}.#{v}"}
    end)
  end

  # --- Scope rendering ---

  defp render_scope(:net, %{hosts: ["*"]}), do: "from any host"

  defp render_scope(:net, %{hosts: hosts}) when hosts != [],
    do: "from #{Enum.join(hosts, ", ")}"

  defp render_scope(:fs, %{paths: ["*"]}), do: "any path (unscoped)"

  defp render_scope(:fs, %{paths: paths}) when paths != [],
    do: "in #{Enum.join(paths, ", ")}"

  defp render_scope(:shell, %{cmds: cmds}) when cmds != [],
    do: "commands: #{Enum.join(cmds, ", ")}"

  defp render_scope(:records, scope) when scope != %{} do
    [
      if(scope[:classes] && scope[:classes] != [],
        do: "classes: #{Enum.join(scope[:classes], ", ")}"
      ),
      if(scope[:paths] && scope[:paths] != [], do: "paths: #{Enum.join(scope[:paths], ", ")}")
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "; ")
    end
  end

  defp render_scope(:agent, %{ids: ids}) when ids != [],
    do: "agents: #{Enum.join(ids, ", ")}"

  defp render_scope(_, _), do: nil
end
