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
  @type scope_type :: :string | :string_list
  @type entry :: %{
          short: String.t(),
          risk: risk(),
          scope_keys: %{atom() => scope_type()}
        }

  # Per-capability schema. `scope_keys` names every scope key the
  # matcher recognizes at dispatch, paired with its value shape —
  # `:string` for scalar ids, `:string_list` for globs/lists. An
  # empty `scope_keys` map means the capability takes no scope; any
  # scope key in yaml is a typo.
  @catalog %{
    # Content records
    {:records, :read} => %{
      short: "Read and search records",
      risk: :low,
      scope_keys: %{}
    },
    {:records, :create} => %{
      short: "Create new content records",
      risk: :low,
      scope_keys: %{classes: :string_list}
    },
    {:records, :update} => %{
      short: "Edit existing content records",
      risk: :medium,
      scope_keys: %{classes: :string_list, paths: :string_list}
    },
    {:records, :delete} => %{
      short: "Delete content records",
      risk: :high,
      scope_keys: %{classes: :string_list}
    },

    # Agents — the authority-bearing operations
    {:agent, :create} => %{
      short: "Create new agents (inert capabilities until granted)",
      risk: :medium,
      scope_keys: %{id: :string}
    },
    {:agent, :update} => %{
      short: "Edit agent disposition, model, tags (not capabilities)",
      risk: :medium,
      scope_keys: %{id: :string, ids: :string_list, paths: :string_list}
    },
    {:agent, :delete} => %{
      short: "Remove agents",
      risk: :high,
      scope_keys: %{id: :string, ids: :string_list}
    },
    {:agent, :grant} => %{
      short: "Grant capabilities to agents (attenuation-bound)",
      risk: :high,
      scope_keys: %{id: :string}
    },

    # Filesystem outside the record store. `in:` declares the sandbox
    # root; `paths:` is an optional list of refinements relative to `in:`.
    {:fs, :read} => %{
      short: "Read files outside the record store",
      risk: :medium,
      scope_keys: %{in: :string, paths: :string_list}
    },
    {:fs, :write} => %{
      short: "Write files outside the record store",
      risk: :high,
      scope_keys: %{in: :string, paths: :string_list}
    },
    {:fs, :delete} => %{
      short: "Delete files outside the record store",
      risk: :high,
      scope_keys: %{in: :string, paths: :string_list}
    },

    # Network — HTTP verbs
    {:net, :get} => %{
      short: "Fetch web pages (HTTP GET)",
      risk: :medium,
      scope_keys: %{hosts: :string_list}
    },
    {:net, :post} => %{
      short: "Submit data to web APIs (HTTP POST)",
      risk: :high,
      scope_keys: %{hosts: :string_list}
    },
    {:net, :put} => %{
      short: "Update remote resources (HTTP PUT)",
      risk: :high,
      scope_keys: %{hosts: :string_list}
    },
    {:net, :delete} => %{
      short: "Delete remote resources (HTTP DELETE)",
      risk: :high,
      scope_keys: %{hosts: :string_list}
    },

    # Processes — spawning OS subprocesses. The `in:` scope is the
    # sandbox root the subprocess runs inside (kernel-enforced via
    # Egghead.Sandbox); `cmds:` and `patterns:` are an Elixir-level
    # argv allow-list refinement on top.
    {:proc, :exec} => %{
      short: "Run allow-listed subprocesses (argv-style, no shell)",
      risk: :high,
      scope_keys: %{in: :string, cmds: :string_list, patterns: :string_list}
    },
    {:proc, :eval} => %{
      short: "Run shell pipelines (bash -c \"...\"); safe only inside a sandbox",
      risk: :high,
      scope_keys: %{in: :string}
    }
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

  @doc """
  All known capability keys as `"resource.verb"` strings. Used by
  validators to detect typos via string-distance suggestions.
  """
  @spec keys() :: [String.t()]
  def keys do
    Enum.map(@catalog, fn {{r, v}, _} -> "#{r}.#{v}" end)
  end

  @doc """
  Scope key schema for `resource.verb` — a map of
  `%{key_atom => :string | :string_list}`. Returns `nil` if the
  `resource.verb` pair is unknown, or an empty map if the capability
  takes no scope keys.
  """
  @spec scope_keys(atom(), atom()) :: %{atom() => scope_type()} | nil
  def scope_keys(resource, verb) do
    case lookup(resource, verb) do
      %{scope_keys: keys} -> keys
      nil -> nil
    end
  end

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

  defp render_scope(:proc, scope) do
    parts =
      [
        render_scope_key(scope, :in, fn v -> "in #{v}" end),
        render_scope_key(scope, :cmds, fn vs -> "commands: #{Enum.join(vs, ", ")}" end),
        render_scope_key(scope, :patterns, fn vs -> "patterns: #{Enum.join(vs, ", ")}" end)
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> nil
      xs -> Enum.join(xs, "; ")
    end
  end

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

  defp render_scope_key(scope, key, fmt) do
    case Map.get(scope, key) do
      nil -> nil
      [] -> nil
      "" -> nil
      val -> fmt.(val)
    end
  end
end
