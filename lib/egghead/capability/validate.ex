defmodule Egghead.Capability.Validate do
  @moduledoc """
  Validates the yaml representation of a `capabilities:` frontmatter
  entry against the catalog schema. Separate from `Capability.parse/1`
  so that parsing stays lenient (unknown entries become inert) while
  validation is explicit and produces human-readable errors.

  Runs in three places:

  - **Tool path** — `req_create_record` / `req_update_record` call
    `validate/1` on `capabilities:` input and hard-fail on error, so
    agents with `agent.grant` get immediate feedback about typos.
  - **Wizard** — programmatic agent creation routes through the same
    validator.
  - **Doctor** — `egghead doctor` iterates `:agent` records and
    surfaces issues as warnings (records always load; this just
    flags problems the human can fix).

  Unknown capability names and scope keys get string-distance
  suggestions via `String.jaro_distance/2` so typos like
  `records.reed` or `fs.write{pathz: ["*"]}` produce actionable
  messages.
  """

  alias Egghead.Capability.Catalog

  @jaro_threshold 0.8

  @type issue :: %{
          entry: term(),
          problem: String.t(),
          suggestion: String.t() | nil
        }

  @doc """
  Validates a yaml-parsed capability list. Accepts the same input
  shapes as `Capability.parse/1`:

  - `nil` — empty, always `:ok`
  - `[]` — empty, always `:ok`
  - List of bare strings (`"records.read"`) or single-key maps
    (`%{"fs.write" => %{"paths" => ["*"]}}`)

  Returns `:ok` if every entry is well-formed against the catalog,
  or `{:error, [issue]}` with one issue per malformed entry.
  """
  @spec validate(term()) :: :ok | {:error, [issue()]}
  def validate(nil), do: :ok
  def validate([]), do: :ok

  def validate(list) when is_list(list) do
    issues = Enum.flat_map(list, &validate_entry/1)
    if issues == [], do: :ok, else: {:error, issues}
  end

  def validate(other) do
    {:error,
     [
       %{
         entry: other,
         problem: "capabilities must be a list, got #{inspect(other)}",
         suggestion: nil
       }
     ]}
  end

  @doc """
  Formats a list of validation issues into a single human-readable
  error string suitable for an agent tool response.
  """
  @spec format_errors([issue()]) :: String.t()
  def format_errors(issues) do
    lines =
      Enum.map(issues, fn issue ->
        base = "  - #{issue.problem}"

        case issue.suggestion do
          nil -> base
          s -> "#{base} (did you mean `#{s}`?)"
        end
      end)

    "capabilities validation failed:\n" <> Enum.join(lines, "\n")
  end

  # --- Per-entry validators ---

  defp validate_entry(str) when is_binary(str) do
    case validate_key(str) do
      :ok -> []
      {:error, issue} -> [issue]
    end
  end

  defp validate_entry(%{} = map) when map_size(map) == 1 do
    [{key, scope}] = Map.to_list(map)
    key_str = to_string(key)

    with :ok <- validate_key(key_str),
         {:ok, {resource, verb}} <- parse_key(key_str),
         :ok <- validate_scope(resource, verb, scope) do
      []
    else
      {:error, issue} -> [issue]
    end
  end

  defp validate_entry(other) do
    [
      %{
        entry: other,
        problem: "expected a capability string or a single-key map, got #{inspect(other)}",
        suggestion: nil
      }
    ]
  end

  defp validate_key(key) do
    case parse_key(key) do
      {:ok, {resource, verb}} ->
        if Catalog.lookup(resource, verb) do
          :ok
        else
          {:error,
           %{
             entry: key,
             problem: "unknown capability `#{key}`",
             suggestion: suggest(key, Catalog.keys())
           }}
        end

      :error ->
        {:error,
         %{
           entry: key,
           problem: "malformed capability `#{key}` — expected `resource.verb`",
           suggestion: suggest(key, Catalog.keys())
         }}
    end
  end

  defp parse_key(str) do
    case String.split(str, ".", parts: 2) do
      [r, v] when r != "" and v != "" ->
        {:ok, {String.to_atom(r), String.to_atom(v)}}

      _ ->
        :error
    end
  end

  defp validate_scope(_resource, _verb, nil), do: :ok

  defp validate_scope(resource, verb, scope) when is_map(scope) do
    key_str = "#{resource}.#{verb}"
    schema = Catalog.scope_keys(resource, verb) || %{}
    allowed = schema |> Map.keys() |> Enum.map(&Atom.to_string/1)

    scope
    |> Enum.flat_map(fn {k, v} ->
      k_str = to_string(k)
      k_atom = String.to_atom(k_str)

      cond do
        not Map.has_key?(schema, k_atom) ->
          [
            %{
              entry: %{key_str => %{k_str => v}},
              problem: "unknown scope key `#{k_str}` on `#{key_str}`",
              suggestion: suggest(k_str, allowed)
            }
          ]

        not valid_scope_value?(Map.fetch!(schema, k_atom), v) ->
          [
            %{
              entry: %{key_str => %{k_str => v}},
              problem:
                "scope `#{k_str}` on `#{key_str}` expected #{describe_type(Map.fetch!(schema, k_atom))}, got #{inspect(v)}",
              suggestion: nil
            }
          ]

        true ->
          []
      end
    end)
    |> case do
      [] -> :ok
      [issue | _] -> {:error, issue}
    end
  end

  defp validate_scope(resource, verb, other) do
    {:error,
     %{
       entry: %{"#{resource}.#{verb}" => other},
       problem: "scope on `#{resource}.#{verb}` must be a map, got #{inspect(other)}",
       suggestion: nil
     }}
  end

  defp valid_scope_value?(:string, val) when is_binary(val), do: true
  defp valid_scope_value?(:string, _), do: false

  defp valid_scope_value?(:string_list, val) when is_list(val),
    do: Enum.all?(val, &is_binary/1)

  defp valid_scope_value?(:string_list, _), do: false

  defp describe_type(:string), do: "a string"
  defp describe_type(:string_list), do: "a list of strings"

  @doc """
  Escalation-risk warnings for capabilities that would let an agent
  circumvent the capability model by editing records directly.
  Narrow by design — only the clearest cases:

  - `fs.write` or `fs.delete` with scope `paths` covering the
    `records_dir` (either literally, prefix-matching, or unbounded
    globs like `"*"` or `"**"`).
  - `proc.exec` / `proc.eval` with no `cmds` and no `patterns`
    (unrestricted process spawn can edit any file the sandbox allows,
    defeating argv-level auditing).

  Takes the raw yaml-parsed capability list and an absolute
  `records_dir` path. Returns a list of human-readable warning
  strings, empty if no escalation risks found.
  """
  @spec escalation_warnings(term(), String.t() | nil) :: [String.t()]
  def escalation_warnings(raw, records_dir)

  def escalation_warnings(nil, _records_dir), do: []

  def escalation_warnings(raw, records_dir) when is_list(raw) do
    Enum.flat_map(raw, &escalation_for_entry(&1, records_dir))
  end

  def escalation_warnings(_, _), do: []

  defp escalation_for_entry(%{} = map, records_dir) when map_size(map) == 1 do
    [{key, scope}] = Map.to_list(map)

    case {to_string(key), scope} do
      {"fs.write", %{} = s} -> fs_covers_records_dir?(s, records_dir, "fs.write")
      {"fs.delete", %{} = s} -> fs_covers_records_dir?(s, records_dir, "fs.delete")
      {"proc.exec", %{} = s} -> proc_unrestricted?(s, "proc.exec")
      {"proc.eval", %{} = s} -> proc_unrestricted?(s, "proc.eval")
      _ -> []
    end
  end

  defp escalation_for_entry("proc.exec", _records_dir),
    do: ["proc.exec granted with no command or pattern restriction"]

  defp escalation_for_entry("proc.eval", _records_dir),
    do: ["proc.eval granted without a sandbox root — any command, anywhere"]

  defp escalation_for_entry(_, _), do: []

  @doc """
  Warnings for external grants (`fs.*`, `proc.*`, `net.*`) that have
  no hoistable sandbox root — i.e. no explicit `in:` on the grant,
  no agent-level `sandbox:`, and no config-level `sandbox:`.

  Such grants appear to exist in the agent's capability list but are
  **inert**: every tool call denies with a scope violation. A silent
  footgun for users who write `capabilities: [fs.read]` expecting it
  to Just Work — historically `paths:` was the scope key, but under
  the sandbox model the expectation shifts. This check flags the
  mismatch with the fix.

  Returns a list of human-readable warning strings naming the
  dangling grants and suggesting where to declare a sandbox.

  `net.*` is **excluded** from this check — network grants use `hosts:`,
  not `in:`, and are perfectly usable without a sandbox root.
  """
  @spec sandbox_warnings(term(), String.t() | nil, String.t() | nil) :: [String.t()]
  def sandbox_warnings(raw, agent_sandbox, config_sandbox)

  def sandbox_warnings(nil, _agent, _config), do: []

  def sandbox_warnings(_raw, agent, config) when is_binary(agent) or is_binary(config),
    do: []

  def sandbox_warnings(raw, _agent, _config) when is_list(raw) do
    dangling =
      raw
      |> Enum.flat_map(&dangling_external_grant/1)
      |> Enum.uniq()

    case dangling do
      [] ->
        []

      names ->
        [
          "external grants have no hoistable `in:` scope: #{Enum.join(names, ", ")}. " <>
            "These grants are inert — tool calls will be denied. Fix: add " <>
            "`sandbox: <path>` to the agent record, or set `sandbox: <path>` in " <>
            "~/.config/egghead/config.yml for a machine-wide root."
        ]
    end
  end

  def sandbox_warnings(_, _, _), do: []

  # Returns ["fs.read"] if the entry is an external FS/proc grant lacking
  # an explicit `in:`; [] otherwise. Net is excluded (it uses `hosts:`).
  defp dangling_external_grant(str) when is_binary(str) do
    case str do
      "fs." <> _ -> [str]
      "proc." <> _ -> [str]
      _ -> []
    end
  end

  defp dangling_external_grant(%{} = map) when map_size(map) == 1 do
    [{key, scope}] = Map.to_list(map)
    key_str = to_string(key)

    cond do
      not (String.starts_with?(key_str, "fs.") or String.starts_with?(key_str, "proc.")) ->
        []

      has_in_scope?(scope) ->
        []

      true ->
        [key_str]
    end
  end

  defp dangling_external_grant(_), do: []

  defp has_in_scope?(%{} = scope) do
    value = scope["in"] || scope[:in]
    is_binary(value) and value != ""
  end

  defp has_in_scope?(_), do: false

  defp fs_covers_records_dir?(_scope, nil, _label), do: []

  defp fs_covers_records_dir?(scope, records_dir, label) do
    paths = scope["paths"] || scope[:paths] || []

    cond do
      not is_list(paths) ->
        []

      Enum.any?(paths, &path_covers?(&1, records_dir)) ->
        ["#{label} scope includes records_dir — agent can bypass the capability model"]

      true ->
        []
    end
  end

  defp path_covers?(pattern, records_dir) when is_binary(pattern) do
    cond do
      pattern in ["*", "**", "/**"] ->
        true

      true ->
        base = pattern |> strip_glob_suffix() |> Path.expand()

        base == records_dir or
          String.starts_with?(records_dir, base <> "/") or
          String.starts_with?(base, records_dir <> "/")
    end
  end

  defp path_covers?(_, _), do: false

  defp strip_glob_suffix(pattern) do
    pattern
    |> String.replace_suffix("/**", "")
    |> String.replace_suffix("/*", "")
    |> String.replace_suffix("/", "")
  end

  defp proc_unrestricted?(scope, label) do
    cmds = scope["cmds"] || scope[:cmds] || []
    patterns = scope["patterns"] || scope[:patterns] || []

    empty_cmds = not is_list(cmds) or cmds == []
    empty_patterns = not is_list(patterns) or patterns == []

    if empty_cmds and empty_patterns do
      ["#{label} granted with no command or pattern restriction"]
    else
      []
    end
  end

  # --- Suggestions ---

  defp suggest(input, candidates) do
    candidates
    |> Enum.map(&{&1, String.jaro_distance(input, &1)})
    |> Enum.filter(fn {_c, score} -> score >= @jaro_threshold end)
    |> Enum.max_by(fn {_c, score} -> score end, fn -> nil end)
    |> case do
      {candidate, _} -> candidate
      nil -> nil
    end
  end
end
