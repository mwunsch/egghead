defmodule Egghead.Eval.Workspace do
  @moduledoc """
  Per-run scratch directory for eval tasks that touch the filesystem
  or shell — coding tasks, primarily.

  Layout under `$XDG_STATE_HOME/egghead/eval-workspaces/<run-id>/`:

      <run-id>/
      ├── workspace/       # agents' cwd; code and artifacts go here
      ├── shell.log        # captured stdout/stderr of shell.exec calls
      └── manifest.yml     # run metadata (run-id, roster, task, status)

  XDG state path — derived, ephemeral, rebuildable — same rationale as
  logs and the SQLite index.

  ## Capability scoping

  Task-roster personas declare bare capabilities
  (`capabilities: [fs.write, shell.exec]`). The Runner calls
  `scope_record/2` before spawning each persona to rewrite the grants
  with paths restricted to the workspace and shell commands clamped
  to a curated allowlist. An agent that picks up a user's store-based
  grants is untouched — the rewrite only fires for known unscoped
  persona caps.

  ## Lifecycle

  Default: delete on success, keep on failure (for debugging). The
  CLI `--keep` flag forces retention even on success; `egghead eval
  prune` (future) reaps stale workspaces on demand.
  """

  require Logger

  # Curated shell allowlist: enough to run Python/Node/Ruby code and
  # their test runners, read the filesystem, and inspect state.
  # Deliberately excludes: rm, sudo, curl, wget, ssh, scp, chmod,
  # chown, cp, mv, and anything that writes outside the workspace or
  # reaches the network.
  @allowed_shell_cmds [
    # interpreters
    "python",
    "python3",
    "node",
    "ruby",
    # test runners (run via `python3 -m pytest` if present)
    "pytest",
    # navigation / inspection (read-only)
    "ls",
    "pwd",
    "cat",
    "head",
    "tail",
    "file",
    "wc",
    "find",
    "grep",
    "diff",
    # directory creation (writes, but scoped to workspace by fs.write)
    "mkdir"
  ]

  @doc """
  Returns the canonical allowlist of shell commands injected into
  eval personas' `shell.exec` grants.
  """
  @spec allowed_shell_cmds() :: [String.t()]
  def allowed_shell_cmds, do: @allowed_shell_cmds

  @doc """
  Root directory for all eval workspaces (`$XDG_STATE_HOME/egghead/eval-workspaces`).
  """
  @spec root() :: String.t()
  def root do
    state_home =
      System.get_env("XDG_STATE_HOME") ||
        Path.join(System.user_home!(), ".local/state")

    Path.join([state_home, "egghead", "eval-workspaces"])
  end

  @doc """
  Path for a specific run's workspace dir.
  """
  @spec path_for(String.t()) :: String.t()
  def path_for(run_id), do: Path.join(root(), run_id)

  @doc """
  Creates the workspace directory tree for a run. Writes a manifest
  with run metadata. Returns the workspace root (the directory that
  contains `workspace/`, `shell.log`, `manifest.yml`).
  """
  @spec create(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def create(run_id, manifest_data) when is_binary(run_id) and is_map(manifest_data) do
    dir = path_for(run_id)
    workspace_dir = Path.join(dir, "workspace")

    try do
      File.mkdir_p!(workspace_dir)
      File.write!(Path.join(dir, "shell.log"), "")
      File.write!(Path.join(dir, "manifest.yml"), render_manifest(manifest_data))
      {:ok, dir}
    rescue
      e -> {:error, {:workspace_create_failed, Exception.message(e)}}
    end
  end

  @doc """
  Cleans up a workspace based on run outcome and the user's `:keep`
  preference. Delete on success unless `keep: true`; always keep on
  failure so the workspace can be inspected.

  Returns `:deleted | :kept`.
  """
  @spec cleanup(String.t(), :ok | :error | :skipped, boolean()) :: :deleted | :kept
  def cleanup(path, status, keep) when is_binary(path) do
    should_keep? = keep or status != :ok

    if should_keep? do
      :kept
    else
      File.rm_rf!(path)
      :deleted
    end
  end

  @doc """
  Rewrites a persona's frontmatter capabilities to be workspace-
  scoped. Bare grants become path-restricted or command-restricted:

      "fs.read"      → %{"fs.read"   => %{"paths" => [workspace/**]}}
      "fs.write"     → %{"fs.write"  => %{"paths" => [workspace/**]}}
      "shell.exec"   → %{"shell.exec" => %{"cmds"  => @allowed_shell_cmds}}

  Already-scoped maps and grants for other resources (records.read,
  etc.) pass through untouched. The returned record is a new struct;
  the input is not mutated.
  """
  @spec scope_record(Egghead.Record.t(), String.t()) :: Egghead.Record.t()
  def scope_record(%Egghead.Record{meta: meta} = record, workspace_path)
      when is_map(meta) and is_binary(workspace_path) do
    workspace_dir = Path.join(workspace_path, "workspace")
    caps = Map.get(meta, "capabilities", [])
    scoped = Enum.map(caps, &scope_one(&1, workspace_dir))
    %{record | meta: Map.put(meta, "capabilities", scoped)}
  end

  def scope_record(record, _), do: record

  defp scope_one("fs.read", ws), do: %{"fs.read" => %{"paths" => [ws <> "/**"]}}
  defp scope_one("fs.write", ws), do: %{"fs.write" => %{"paths" => [ws <> "/**"]}}
  defp scope_one("shell.exec", _ws), do: %{"shell.exec" => %{"cmds" => @allowed_shell_cmds}}
  defp scope_one(other, _ws), do: other

  # ---- manifest rendering -------------------------------------------------

  defp render_manifest(data) do
    # Hand-rolled YAML rather than pulling in a YAML writer. Values
    # are either scalars or lists of scalars — well within what
    # `inspect/1` can handle correctly for our purposes.
    [
      "run_id: #{esc(data[:run_id])}",
      "task: #{esc(data[:task])}",
      "roster: #{inspect(data[:roster] || [])}",
      "started_at: #{esc(data[:started_at] || DateTime.utc_now() |> DateTime.to_iso8601())}",
      "status: in_progress"
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp esc(nil), do: "~"

  defp esc(value) when is_binary(value) do
    if String.contains?(value, [":", "#", "\n"]),
      do: ~s("#{String.replace(value, ~s("), ~s(\\"))}"),
      else: value
  end

  defp esc(value), do: inspect(value)
end
