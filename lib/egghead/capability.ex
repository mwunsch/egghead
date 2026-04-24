defmodule Egghead.Capability do
  @moduledoc """
  Per-agent, record-declared, parameter-scoped authority.

  An agent's frontmatter lists capabilities; `parse/1` turns that list
  into `%Grant{}` structs. At tool-dispatch time, each tool constructs a
  `%Request{}` describing what it's about to do, and `check/3` decides
  whether the request is covered by the held grants.

  Widening capabilities requires editing the agent's frontmatter — a
  human act. Narrowing is always permitted. Runtime denial produces a
  `%Denial{}` that surfaces to the LLM, the transcript, and the log.
  """

  require Logger

  alias Egghead.Capability.Denial
  alias Egghead.Capability.Grant
  alias Egghead.Capability.Matcher
  alias Egghead.Capability.Request

  @resources ~w(records agent fs net proc)a

  # External resources touch the world outside Egghead — bare grants
  # (empty scope) are inert until explicitly scoped. Internal resources
  # (records, agent) default bare-to-universe.
  @external_resources [:fs, :net, :proc]

  # `shell.*` was renamed to `proc.*` — kept as a deprecated alias for one
  # release so existing agent records continue to load with a warning.
  @deprecated_aliases %{"shell" => "proc"}

  @doc "True if the resource touches outside-Egghead state."
  def external?(resource), do: resource in @external_resources

  @doc """
  Parses a frontmatter `capabilities:` value into a list of grants.

  Accepts:
  - A list of strings: `["records.read", "agent.create"]`
  - A list mixing strings and maps (scoped): `["records.read", %{"net.get" => %{"hosts" => [...]}}]`
  - A comma/space-separated string: `"records.read agent.create"`

  Unknown strings are logged and dropped (forward-compat for skills
  referencing future capability names).
  """
  @spec parse(term()) :: [Grant.t()]
  def parse(nil), do: []

  def parse(list) when is_list(list) do
    list
    |> Enum.flat_map(&parse_one/1)
    |> merge_duplicates()
  end

  def parse(str) when is_binary(str) do
    str
    |> String.split(~r/[,\s]+/, trim: true)
    |> parse()
  end

  def parse(other) do
    Logger.warning("Capability.parse: unsupported value #{inspect(other)}")
    []
  end

  defp parse_one(str) when is_binary(str) do
    case split_resource_verb(str) do
      {:ok, resource, verb} -> [%Grant{resource: resource, verb: verb, scope: %{}}]
      :error -> warn_drop(str)
    end
  end

  defp parse_one(%{} = map) when map_size(map) == 1 do
    [{key, scope_raw}] = Map.to_list(map)

    with {:ok, resource, verb} <- split_resource_verb(to_string(key)),
         scope when is_map(scope) <- atomize_scope(scope_raw) do
      [%Grant{resource: resource, verb: verb, scope: scope}]
    else
      _ -> warn_drop(map)
    end
  end

  defp parse_one(other), do: warn_drop(other)

  defp split_resource_verb(str) do
    case String.split(str, ".", parts: 2) do
      [r, v] ->
        {r, deprecated?} = canonical_resource(r)
        r_atom = safe_atom(r)

        cond do
          r_atom in @resources and deprecated? ->
            Logger.warning("Capability: `#{str}` is a deprecated alias — use `#{r}.#{v}` instead")

            {:ok, r_atom, safe_atom(v)}

          r_atom in @resources ->
            {:ok, r_atom, safe_atom(v)}

          true ->
            :error
        end

      _ ->
        :error
    end
  end

  defp canonical_resource(raw) do
    case Map.get(@deprecated_aliases, raw) do
      nil -> {raw, false}
      new -> {new, true}
    end
  end

  defp safe_atom(str), do: String.to_atom(str)

  defp atomize_scope(nil), do: %{}

  defp atomize_scope(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {safe_atom(to_string(k)), v} end)
  end

  defp atomize_scope(_), do: nil

  defp warn_drop(value) do
    Logger.warning("Capability.parse: unknown capability #{inspect(value)} — ignored")
    []
  end

  # Merge grants with the same resource.verb by unioning list-valued scope keys.
  defp merge_duplicates(grants) do
    grants
    |> Enum.group_by(&{&1.resource, &1.verb})
    |> Enum.map(fn {{r, v}, items} ->
      merged_scope =
        Enum.reduce(items, %{}, fn %Grant{scope: s}, acc -> merge_scopes(acc, s) end)

      %Grant{resource: r, verb: v, scope: merged_scope}
    end)
  end

  defp merge_scopes(a, b) do
    Map.merge(a, b, fn _k, av, bv ->
      cond do
        is_list(av) and is_list(bv) -> Enum.uniq(av ++ bv)
        true -> bv
      end
    end)
  end

  @doc """
  Checks a request against a list of held grants.

  Returns `:ok` or `{:denied, %Denial{}}`. The `ctx` map is used to
  populate `agent_id` and to run the self-modification guard (`agent_id`
  must be set for that check to fire).
  """
  @spec check([Grant.t()], Request.t(), map()) :: :ok | {:denied, Denial.t()}
  def check(grants, %Request{} = request, ctx \\ %{}) do
    with :ok <- check_self_modification(grants, request, ctx),
         :ok <- check_held(grants, request, ctx),
         :ok <- check_attenuation(grants, request, ctx) do
      :ok
    end
  end

  defp check_self_modification(_grants, %Request{resource: :agent, verb: :grant} = req, ctx) do
    deny_self_target(
      req,
      ctx,
      "agent cannot grant capabilities to itself — human must edit the agent record directly"
    )
  end

  defp check_self_modification(_grants, %Request{resource: :agent, verb: :delete} = req, ctx) do
    # `delete_record` on an agent's own record would terminate the
    # caller mid-tool-use. Denied; trash by hand.
    deny_self_target(req, ctx, "agent cannot delete its own record")
  end

  defp check_self_modification(_grants, _req, _ctx), do: :ok

  defp deny_self_target(req, ctx, message) do
    agent_id = Map.get(ctx, :agent_id)
    target_id = Map.get(req.scope, :id)

    if agent_id && target_id == agent_id do
      {:denied,
       %Denial{
         code: :self_modification,
         request: req,
         agent_id: agent_id,
         tool: req.tool,
         message: message,
         suggested_grant: nil
       }}
    else
      :ok
    end
  end

  defp check_attenuation(
         grants,
         %Request{resource: :agent, verb: :grant, scope: scope} = req,
         ctx
       ) do
    case Map.get(scope, :granted) do
      nil ->
        :ok

      [] ->
        :ok

      proposed when is_list(proposed) ->
        if subset?(proposed, grants) do
          :ok
        else
          {:denied,
           %Denial{
             code: :exceeds_grantor_authority,
             request: req,
             held: grants,
             agent_id: Map.get(ctx, :agent_id),
             tool: req.tool,
             message:
               "proposed capabilities exceed granter's own authority — grants must be subset",
             suggested_grant: nil
           }}
        end
    end
  end

  defp check_attenuation(_grants, _req, _ctx), do: :ok

  defp check_held(grants, %Request{} = request, ctx) do
    matching =
      Enum.filter(grants, fn %Grant{resource: r, verb: v} ->
        r == request.resource and v == request.verb
      end)

    case matching do
      [] ->
        {:denied,
         %Denial{
           code: :capability_absent,
           request: request,
           held: grants,
           agent_id: Map.get(ctx, :agent_id),
           tool: request.tool,
           message: "no grant for #{Request.key(request)}",
           suggested_grant: suggest_grant(request)
         }}

      grants_for_verb ->
        case any_scope_matches?(grants_for_verb, request, ctx) do
          :ok ->
            :ok

          {:scope_violation, reason} ->
            {:denied,
             %Denial{
               code: :scope_violation,
               request: request,
               held: grants_for_verb,
               agent_id: Map.get(ctx, :agent_id),
               tool: request.tool,
               message: "#{Request.key(request)}: #{reason}",
               suggested_grant: suggest_grant(request)
             }}
        end
    end
  end

  defp any_scope_matches?(grants, request, ctx) do
    hoist = hoisted_sandbox(ctx)

    Enum.reduce_while(grants, {:scope_violation, "no matching scope"}, fn grant, _last ->
      effective_scope = apply_hoist(grant.scope, hoist)

      case Matcher.check(effective_scope, request.scope, request.resource, request.verb) do
        :ok -> {:halt, :ok}
        {:scope_violation, _} = err -> {:cont, err}
      end
    end)
  end

  # Hoist chain: grant.scope[:in] (explicit) → agent sandbox → config sandbox.
  # The deepest declared value wins; missing values inherit from the level
  # above. Returns the effective sandbox path, or `nil` if no level set one.
  defp hoisted_sandbox(ctx) do
    Map.get(ctx, :agent_sandbox) || Map.get(ctx, :config_sandbox)
  end

  defp apply_hoist(scope, nil), do: scope

  defp apply_hoist(scope, hoist) do
    # An explicit `in:` on the grant takes precedence. Only fill in when
    # missing — this is inheritance, never override.
    Map.put_new(scope, :in, hoist)
  end

  @doc """
  Parses a compact grant spec string (the form `egghead agent grant`
  accepts) into the data shape consumable by `parse/1`.

  Accepts:

      records.read
      net.get{hosts=[*.github.com,api.anthropic.com]}
      proc.exec{cmds=[rg,jq],patterns=[git:*]}
      fs.read{paths=[~/projects/**]}

  Returns `{:ok, value}` where `value` is a string (bare form) or a
  map `%{resource_verb => scope_map}` suitable for `Capability.parse/1`.
  Returns `{:error, reason}` on parse failure.
  """
  @spec parse_grant_spec(String.t()) :: {:ok, term()} | {:error, String.t()}
  def parse_grant_spec(str) when is_binary(str) do
    trimmed = String.trim(str)

    cond do
      trimmed == "" ->
        {:error, "empty spec"}

      String.contains?(trimmed, "{") ->
        parse_scoped(trimmed)

      true ->
        {:ok, trimmed}
    end
  end

  defp parse_scoped(str) do
    with [verb_part, rest] <- String.split(str, "{", parts: 2),
         true <- String.ends_with?(rest, "}") or {:error, "missing closing }"},
         scope_body <- String.trim_trailing(rest, "}"),
         {:ok, scope_map} <- parse_scope_body(scope_body) do
      {:ok, %{String.trim(verb_part) => scope_map}}
    else
      {:error, _} = err -> err
      _ -> {:error, "malformed spec: #{str}"}
    end
  end

  defp parse_scope_body(body) do
    # Split on top-level commas (not inside [...])
    pairs = split_top_level(body, ",")

    result =
      Enum.reduce_while(pairs, {:ok, %{}}, fn pair, {:ok, acc} ->
        case String.split(String.trim(pair), "=", parts: 2) do
          [key, value] ->
            parsed_value = parse_scope_value(String.trim(value))
            {:cont, {:ok, Map.put(acc, String.trim(key), parsed_value)}}

          _ ->
            {:halt, {:error, "malformed scope pair: #{pair}"}}
        end
      end)

    result
  end

  defp parse_scope_value("[" <> rest) do
    inner = String.trim_trailing(rest, "]")

    inner
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_scope_value(raw), do: raw

  # Splits on `,` but skips commas inside balanced `[...]` brackets.
  defp split_top_level(str, delim) do
    {acc, current, _depth} =
      str
      |> String.graphemes()
      |> Enum.reduce({[], "", 0}, fn
        "[", {acc, cur, d} -> {acc, cur <> "[", d + 1}
        "]", {acc, cur, d} -> {acc, cur <> "]", max(0, d - 1)}
        ^delim, {acc, cur, 0} -> {[cur | acc], "", 0}
        ch, {acc, cur, d} -> {acc, cur <> ch, d}
      end)

    Enum.reverse([current | acc])
  end

  @doc """
  Formats a `%Grant{}` back to the compact spec string suitable for
  `egghead agent grant`. Round-trips with `parse_grant_spec/1`.
  """
  @spec grant_to_spec(Grant.t()) :: String.t()
  def grant_to_spec(%Grant{resource: r, verb: v, scope: scope}) when scope == %{} do
    "#{r}.#{v}"
  end

  def grant_to_spec(%Grant{resource: r, verb: v, scope: scope}) do
    pairs =
      Enum.map_join(scope, ",", fn {k, v} ->
        "#{k}=#{format_scope_value(v)}"
      end)

    "#{r}.#{v}{#{pairs}}"
  end

  defp format_scope_value(v) when is_list(v), do: "[" <> Enum.join(v, ",") <> "]"
  defp format_scope_value(v), do: to_string(v)

  @doc """
  Formats a `%Grant{}` back to its yaml-frontmatter form: a bare string
  for unscoped grants, a single-key map (string-keyed) for scoped. Round-
  trips with `parse/1` at the entry level — the output is safe to concat
  into a `capabilities:` list and write to a record.
  """
  @spec grant_to_yaml(Grant.t()) :: String.t() | map()
  def grant_to_yaml(%Grant{resource: r, verb: v, scope: scope}) when scope == %{} do
    "#{r}.#{v}"
  end

  def grant_to_yaml(%Grant{resource: r, verb: v, scope: scope}) do
    %{"#{r}.#{v}" => Map.new(scope, fn {k, val} -> {to_string(k), val} end)}
  end

  @doc "Suggests a YAML snippet the human could add to widen a grant for this request."
  @spec suggest_grant(Request.t()) :: String.t()
  def suggest_grant(%Request{resource: :net, verb: v, scope: %{host: host}}) do
    "net.#{v}{hosts=[#{host}]}"
  end

  def suggest_grant(%Request{resource: :fs, verb: v, scope: %{path: path}}) do
    "fs.#{v}{paths=[#{path}]}"
  end

  def suggest_grant(%Request{resource: :proc, verb: :exec, scope: %{cmd: cmd}}) do
    "proc.exec{cmds=[#{cmd}]}"
  end

  def suggest_grant(%Request{resource: r, verb: v}), do: "#{r}.#{v}"

  @doc """
  Returns a MapSet of `"resource.verb"` strings held by the grants.
  Used by tool-offering logic to decide which tools to expose to the LLM.
  """
  @spec verbs_held([Grant.t()]) :: MapSet.t()
  def verbs_held(grants) do
    grants |> Enum.map(&Grant.key/1) |> MapSet.new()
  end

  @doc """
  Is the `child` grant set entirely covered by the `parent` grant set?

  Used by `agent.grant` attenuation: the capabilities being granted to a
  child agent must not exceed the granter's own authority. Every child
  grant must be matched by a parent grant with the same `resource.verb`
  AND a scope that covers the child's scope.

  Semantics for scope coverage are resource-family-specific:

  - External resources (`fs.*`, `net.*`, `proc.*`): parent `hosts`/`paths`/
    `cmds` must contain all child entries (treating `*` globs on the parent
    side as covering matching child entries). An empty parent scope covers
    only an empty child scope — the "bare" grant is the empty set.
  - Internal resources (`records.*`, `agent.*`): bare parent scope covers
    any child scope (universe). A scoped parent requires the child's
    `classes`/`paths`/`ids` to be ⊆ the parent's.
  """
  @spec subset?([Grant.t()], [Grant.t()]) :: boolean()
  def subset?(child, parent) when is_list(child) and is_list(parent) do
    Enum.all?(child, fn cg -> covered_by?(cg, parent) end)
  end

  defp covered_by?(%Grant{} = child, parent_list) do
    parent_list
    |> Enum.filter(fn %Grant{resource: r, verb: v} ->
      r == child.resource and v == child.verb
    end)
    |> Enum.any?(fn p -> scope_covers?(p.scope, child.scope, child.resource) end)
  end

  # External resources: empty parent scope allows nothing. Child must be
  # covered entry-wise.
  defp scope_covers?(parent_scope, child_scope, resource) when resource in [:fs, :net, :proc] do
    key = scope_key_for(resource)
    parent_items = Map.get(parent_scope, key, [])
    child_items = Map.get(child_scope, key, [])

    cond do
      parent_items == [] and child_items == [] -> true
      parent_items == [] -> false
      true -> Enum.all?(child_items, fn ci -> covered_item?(ci, parent_items, resource) end)
    end
  end

  # Internal resources: bare parent covers any child.
  defp scope_covers?(parent_scope, child_scope, _resource) when map_size(parent_scope) == 0 do
    _ = child_scope
    true
  end

  defp scope_covers?(parent_scope, child_scope, :records) do
    child_classes = List.wrap(Map.get(child_scope, :classes, []))
    parent_classes = List.wrap(Map.get(parent_scope, :classes, []))
    child_paths = List.wrap(Map.get(child_scope, :paths, []))
    parent_paths = List.wrap(Map.get(parent_scope, :paths, []))

    classes_ok =
      parent_classes == [] or
        (child_classes != [] and
           Enum.all?(child_classes, fn c ->
             to_string(c) in Enum.map(parent_classes, &to_string/1)
           end))

    paths_ok =
      parent_paths == [] or
        (child_paths != [] and
           Enum.all?(child_paths, fn cp ->
             Enum.any?(parent_paths, fn pp -> Egghead.Capability.Matcher.path_matches?(cp, pp) end)
           end))

    classes_ok and paths_ok
  end

  defp scope_covers?(parent_scope, child_scope, :agent) do
    child_ids = List.wrap(Map.get(child_scope, :ids, []))
    parent_ids = List.wrap(Map.get(parent_scope, :ids, []))

    parent_ids == [] or
      (child_ids != [] and Enum.all?(child_ids, fn id -> id in parent_ids end))
  end

  defp scope_key_for(:fs), do: :paths
  defp scope_key_for(:net), do: :hosts
  defp scope_key_for(:proc), do: :cmds

  # Child item covered by parent list — exact or glob match.
  defp covered_item?(child_item, parent_items, :net) do
    Enum.any?(parent_items, fn p -> Egghead.Capability.Matcher.host_matches?(child_item, p) end)
  end

  defp covered_item?(child_item, parent_items, :fs) do
    Enum.any?(parent_items, fn p -> Egghead.Capability.Matcher.path_matches?(child_item, p) end)
  end

  defp covered_item?(child_item, parent_items, :proc) do
    to_string(child_item) in Enum.map(parent_items, &to_string/1)
  end
end
