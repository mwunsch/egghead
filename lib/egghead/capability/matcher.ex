defmodule Egghead.Capability.Matcher do
  @moduledoc """
  Scope-matching primitives for capability checks. A grant's scope is an
  allow-list; a request's scope is a concrete instance. The matcher
  decides whether the instance falls inside the allow-list.

  Split out from `Egghead.Capability` so it's independently testable —
  host globs, path globs, and class/tag membership are the fiddly bits.
  """

  @doc """
  Checks whether a request's concrete scope is covered by a grant's
  allow-list scope. Returns `:ok` on match, `{:scope_violation, reason}`
  otherwise.

  Rules by resource:

  - `net.*` — match `host` against `hosts` glob list
  - `fs.*` — match `path` against `paths` glob list
  - `shell.exec` — match `cmd` against `cmds` exact list
  - `records.create`/`update`/`delete` — match `class`/`id` against
    `classes`/`paths` allow-lists; empty scope = universe (internal resource)
  - `records.read` — always matches (read is broad)
  - `agent.*` — match `id` against `ids`/`paths` (if scope present); empty
    scope = any agent (internal resource)

  External resources (`fs.*`, `net.*`, `shell.*`): empty grant scope means
  nothing matches (inert until scoped).
  Internal resources (`records.*`, `agent.*`): empty scope means universe.
  """
  @spec check(grant_scope :: map(), request :: map(), resource :: atom(), verb :: atom()) ::
          :ok | {:scope_violation, String.t()}
  def check(grant_scope, request_scope, resource, verb)

  # --- Network ---
  def check(grant_scope, %{host: host}, :net, _verb) do
    hosts = Map.get(grant_scope, :hosts, [])

    cond do
      hosts == [] ->
        {:scope_violation, "host #{host} not allowed (no hosts in grant)"}

      Enum.any?(hosts, &host_matches?(host, &1)) ->
        :ok

      true ->
        {:scope_violation, "host #{host} not in allow-list #{inspect(hosts)}"}
    end
  end

  # --- Filesystem ---
  def check(grant_scope, %{path: path}, :fs, _verb) do
    paths = Map.get(grant_scope, :paths, [])
    expanded = expand_path(path)

    cond do
      paths == [] ->
        {:scope_violation, "path #{path} not allowed (no paths in grant)"}

      Enum.any?(paths, &path_matches?(expanded, expand_path(&1))) ->
        :ok

      true ->
        {:scope_violation, "path #{path} not in allow-list #{inspect(paths)}"}
    end
  end

  # --- Shell ---
  # Request scope is `%{cmd: argv[0], argv: [argv0, arg1, ...]}`.
  # Grant scope supports `cmds:` (argv[0] allowlist) and `patterns:`
  # (full-invocation glob); delegates to Tool.Pattern.
  def check(grant_scope, request_scope, :shell, :exec) do
    argv =
      Map.get(request_scope, :argv) ||
        [to_string(Map.get(request_scope, :cmd, ""))]

    Egghead.Tool.Pattern.check(argv, grant_scope)
  end

  # --- Records.update with optional class/path scoping ---
  def check(grant_scope, request_scope, :records, :update) do
    classes = Map.get(grant_scope, :classes, :any)
    paths = Map.get(grant_scope, :paths, :any)

    class_ok =
      classes == :any or
        Map.get(request_scope, :class) == nil or
        to_string(Map.get(request_scope, :class)) in Enum.map(List.wrap(classes), &to_string/1)

    path_ok =
      paths == :any or
        Map.get(request_scope, :id) == nil or
        Enum.any?(List.wrap(paths), &path_matches?(Map.get(request_scope, :id), &1))

    cond do
      not class_ok ->
        {:scope_violation,
         "class #{Map.get(request_scope, :class)} not in allow-list #{inspect(classes)}"}

      not path_ok ->
        {:scope_violation,
         "record id #{Map.get(request_scope, :id)} not in allow-list #{inspect(paths)}"}

      true ->
        :ok
    end
  end

  # --- Records.create / delete with optional class scoping ---
  def check(grant_scope, request_scope, :records, verb) when verb in [:create, :delete] do
    classes = Map.get(grant_scope, :classes, :any)
    req_class = Map.get(request_scope, :class)

    cond do
      classes == :any ->
        :ok

      req_class && to_string(req_class) in Enum.map(List.wrap(classes), &to_string/1) ->
        :ok

      true ->
        {:scope_violation, "class #{req_class} not in allow-list #{inspect(classes)}"}
    end
  end

  # --- Records.read — broad ---
  def check(_grant_scope, _request_scope, :records, :read), do: :ok

  # --- Agent.* — optional id/paths scoping; bare = any agent ---
  def check(grant_scope, request_scope, :agent, _verb) do
    ids = Map.get(grant_scope, :ids, :any)
    paths = Map.get(grant_scope, :paths, :any)
    req_id = Map.get(request_scope, :id)

    cond do
      ids == :any and paths == :any ->
        :ok

      req_id == nil ->
        :ok

      ids != :any and req_id in List.wrap(ids) ->
        :ok

      paths != :any and Enum.any?(List.wrap(paths), &path_matches?(req_id, &1)) ->
        :ok

      true ->
        {:scope_violation, "agent #{req_id} not in allow-list"}
    end
  end

  def check(_grant_scope, _request_scope, _resource, _verb),
    do: {:scope_violation, "no matcher for resource"}

  # --- Host glob ---

  @doc "Matches a hostname against a glob like `*.github.com`."
  @spec host_matches?(String.t(), String.t()) :: boolean()
  def host_matches?(host, pattern) do
    host = String.downcase(host || "")
    pattern = String.downcase(pattern || "")

    cond do
      pattern == host -> true
      String.starts_with?(pattern, "*.") -> suffix_match?(host, String.slice(pattern, 2..-1//1))
      pattern == "*" -> true
      true -> false
    end
  end

  defp suffix_match?(host, suffix) do
    host == suffix or String.ends_with?(host, "." <> suffix)
  end

  # --- Path glob ---

  @doc "Matches a path against a glob like `~/projects/**` or `scratch/**`."
  @spec path_matches?(String.t(), String.t()) :: boolean()
  def path_matches?(path, pattern) do
    regex = glob_to_regex(pattern)
    Regex.match?(regex, path)
  end

  defp glob_to_regex(pattern) do
    escaped =
      pattern
      |> Regex.escape()
      # undo escapes of our glob metacharacters
      |> String.replace("\\*\\*", "__DOUBLESTAR__")
      |> String.replace("\\*", "[^/]*")
      |> String.replace("__DOUBLESTAR__", ".*")
      |> String.replace("\\?", "[^/]")

    Regex.compile!("^" <> escaped <> "$")
  end

  defp expand_path(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "~/") -> Path.expand(path)
      String.starts_with?(path, "~") -> Path.expand(path)
      true -> path
    end
  end

  defp expand_path(path), do: path
end
