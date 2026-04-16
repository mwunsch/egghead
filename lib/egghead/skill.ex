defmodule Egghead.Skill do
  @moduledoc """
  Skill conformance against the Agent Skills specification
  (https://agentskills.io/specification).

  Skills in Egghead are records with `class: skill`. They come from
  three sources, all unified in the index:

  1. `SKILLS_DIR` (e.g. `~/.agents/skills/<name>/SKILL.md`) — the
     standard drop zone, auto-indexed as virtual skill records.
  2. Record store with explicit `class: skill` frontmatter.
  3. Record store by path convention: any file at
     `skills/<name>/SKILL.md` inside `records_dir` is promoted to
     `class: skill` automatically.

  This module does not hold any skill state — skills are just records.
  It provides:

  - `validate/1` — checks a record against the Agent Skills spec.
  - `derive_name/1` — computes the canonical name (from frontmatter or
    path-derived id).
  - `parse_allowed_tools/1` — converts the spec's `allowed-tools`
    string into capability requests (for future wiring in step 5).
  """

  alias Egghead.Record

  @max_name_len 64
  @max_description_len 1024
  @max_compatibility_len 500

  @type issue :: String.t()
  @type validation :: :ok | {:error, [issue()]}

  @doc """
  Validates a record against the Agent Skills spec. Returns `:ok`
  if the record is a conforming skill, `{:error, issues}` otherwise.

  Issues are human-readable strings — `egghead skills list` surfaces
  them so the user can see why a record is malformed.
  """
  @spec validate(Record.t()) :: validation()
  def validate(%Record{} = record) do
    issues =
      []
      |> validate_name(record)
      |> validate_description(record)
      |> validate_compatibility(record)
      |> validate_body(record)

    if issues == [], do: :ok, else: {:error, Enum.reverse(issues)}
  end

  @doc "Computes the canonical name of a skill from its record."
  @spec derive_name(Record.t()) :: String.t()
  def derive_name(%Record{meta: meta, id: id}) do
    case meta["name"] do
      name when is_binary(name) and name != "" -> name
      _ -> name_from_id(id)
    end
  end

  @doc """
  Returns `true` if a record id looks like a skill by path convention:
  id starts with `skills/` and is either `skills/<name>` or
  `skills/<name>/SKILL` (no deeper nesting).

  Used by the record store and the index rebuild to auto-promote
  records matching this pattern to `class: skill`.
  """
  @spec by_convention?(String.t() | nil) :: boolean()
  def by_convention?(id) when is_binary(id) do
    String.starts_with?(id, "skills/") and
      (String.ends_with?(id, "/SKILL") or
         not String.contains?(String.replace_prefix(id, "skills/", ""), "/"))
  end

  def by_convention?(_), do: false

  @doc """
  Applies auto-classification to a record:

  - If the record is a skill (already declared or promoted by convention)
    AND its id ends with `/SKILL`, the `/SKILL` suffix is stripped.
    `skills/foo/SKILL` becomes `skills/foo` — the SKILL.md basename is
    an artifact of the Agent Skills directory layout, not part of the
    logical id.
  - If the record's id matches `by_convention?/1` and it isn't already
    classed as skill, the class is promoted to `:skill`.

  Records that aren't skills pass through untouched.
  """
  @spec auto_classify(Record.t()) :: Record.t()
  def auto_classify(%Record{class: :skill, id: id} = record) do
    %{record | id: normalize_id(id)}
  end

  def auto_classify(%Record{id: id} = record) do
    if by_convention?(id) do
      %{record | class: :skill, id: normalize_id(id)}
    else
      record
    end
  end

  defp normalize_id(id) when is_binary(id), do: String.replace_suffix(id, "/SKILL", "")
  defp normalize_id(id), do: id

  @doc """
  Derives the list of `%Capability.Request{}`s a skill would need
  in order to execute successfully. Parses `allowed-tools` with
  `parse_allowed_tools/1`, then maps each token through a known-tool
  translation table.

  Returns a map with:

    %{
      requests: [%Request{}, ...],
      unknown: ["FooTool(...)", ...],    # tokens we couldn't map
      warnings: [...]
    }

  Unknown tokens don't block — they surface as warnings the user
  can see in `egghead skills check`, prompting them to either grant
  a broader capability or skip the skill.
  """
  @spec derive_requirements(Record.t()) :: %{
          requests: [Egghead.Capability.Request.t()],
          unknown: [String.t()],
          warnings: [String.t()]
        }
  def derive_requirements(%Record{meta: meta}) do
    tokens = parse_allowed_tools(meta["allowed-tools"])

    Enum.reduce(tokens, %{requests: [], unknown: [], warnings: []}, fn token, acc ->
      case token_to_requests(token) do
        {:ok, reqs} ->
          %{acc | requests: acc.requests ++ reqs}

        :unknown ->
          %{acc | unknown: [token | acc.unknown]}
      end
    end)
  end

  # Translation table — Claude Code / Agent Skills tokens → our
  # capability %Request{}s. `*` wildcards pass through as our
  # auditable-wildcard convention.
  defp token_to_requests("Bash(" <> rest) do
    case String.trim_trailing(rest, ")") do
      "*" ->
        {:ok, [request(:shell, :exec, %{patterns: ["*"]})]}

      pattern ->
        if String.contains?(pattern, ":") do
          {:ok, [request(:shell, :exec, %{patterns: [pattern]})]}
        else
          {:ok, [request(:shell, :exec, %{patterns: [pattern]})]}
        end
    end
  end

  defp token_to_requests("Bash"),
    do: {:ok, [request(:shell, :exec, %{patterns: ["*"]})]}

  defp token_to_requests("Read"),
    do: {:ok, [request(:fs, :read, %{})]}

  defp token_to_requests("Read(" <> rest) do
    path = String.trim_trailing(rest, ")")
    {:ok, [request(:fs, :read, %{paths: [path]})]}
  end

  defp token_to_requests("Write"),
    do: {:ok, [request(:fs, :write, %{})]}

  defp token_to_requests("Write(" <> rest) do
    path = String.trim_trailing(rest, ")")
    {:ok, [request(:fs, :write, %{paths: [path]})]}
  end

  defp token_to_requests("Edit"),
    do: {:ok, [request(:fs, :write, %{})]}

  defp token_to_requests("Edit(" <> rest) do
    path = String.trim_trailing(rest, ")")
    {:ok, [request(:fs, :write, %{paths: [path]})]}
  end

  defp token_to_requests("Glob"),
    do: {:ok, [request(:fs, :read, %{})]}

  defp token_to_requests("Grep"),
    do: {:ok, [request(:fs, :read, %{})]}

  defp token_to_requests("WebFetch") do
    {:ok,
     [
       request(:net, :get, %{}),
       request(:net, :post, %{})
     ]}
  end

  defp token_to_requests("WebFetch(" <> rest) do
    inner = String.trim_trailing(rest, ")")

    host =
      case String.split(inner, ":", parts: 2) do
        ["domain", host] -> host
        [raw] -> raw
        _ -> inner
      end

    {:ok,
     [
       request(:net, :get, %{hosts: [host]}),
       request(:net, :post, %{hosts: [host]})
     ]}
  end

  defp token_to_requests("WebSearch") do
    # Conservatively require both fetch verbs — the actual search
    # implementation lives behind the provider/MCP layer we build next.
    {:ok,
     [
       request(:net, :get, %{}),
       request(:net, :post, %{})
     ]}
  end

  defp token_to_requests(_), do: :unknown

  defp request(resource, verb, scope) do
    %Egghead.Capability.Request{resource: resource, verb: verb, scope: scope}
  end

  @doc """
  Parses the spec's `allowed-tools` frontmatter string (e.g.
  `"Bash(git:*) Bash(jq:*) Read"`) into a list of loose tool
  references. These are mapped to capability requests by
  `derive_requirements/1`.
  """
  @spec parse_allowed_tools(term()) :: [String.t()]
  def parse_allowed_tools(nil), do: []
  def parse_allowed_tools([]), do: []

  def parse_allowed_tools(str) when is_binary(str) do
    str
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 == ""))
  end

  def parse_allowed_tools(list) when is_list(list), do: Enum.map(list, &to_string/1)
  def parse_allowed_tools(_), do: []

  # --- validators ---

  @name_regex ~r/^[a-z0-9](?:[a-z0-9]|-(?!-))*[a-z0-9]$|^[a-z0-9]$/

  defp validate_name(issues, %Record{meta: meta, id: id}) do
    name = meta["name"] || name_from_id(id)

    cond do
      not is_binary(name) or name == "" ->
        ["name is required" | issues]

      String.length(name) > @max_name_len ->
        ["name must be #{@max_name_len} characters or fewer" | issues]

      not Regex.match?(@name_regex, name) ->
        [
          "name #{inspect(name)} must be lowercase alphanumeric + hyphens (no leading/trailing/consecutive hyphens)"
          | issues
        ]

      true ->
        issues
    end
  end

  defp validate_description(issues, %Record{meta: meta}) do
    case meta["description"] do
      desc when is_binary(desc) and desc != "" ->
        if String.length(desc) > @max_description_len do
          ["description must be #{@max_description_len} characters or fewer" | issues]
        else
          issues
        end

      _ ->
        ["description is required and must be non-empty" | issues]
    end
  end

  defp validate_compatibility(issues, %Record{meta: meta}) do
    case meta["compatibility"] do
      nil ->
        issues

      compat when is_binary(compat) ->
        if String.length(compat) > @max_compatibility_len do
          ["compatibility must be #{@max_compatibility_len} characters or fewer" | issues]
        else
          issues
        end

      _ ->
        ["compatibility must be a string" | issues]
    end
  end

  defp validate_body(issues, %Record{body: body}) do
    case body do
      b when is_binary(b) and b != "" -> issues
      _ -> ["body is empty — a skill must provide instructions" | issues]
    end
  end

  # A skill id like "skills/mansplain" or "skills/mansplain/SKILL" → "mansplain"
  defp name_from_id(id) when is_binary(id) do
    id
    |> String.replace_prefix("skills/", "")
    |> String.replace_suffix("/SKILL", "")
  end

  defp name_from_id(_), do: ""
end
