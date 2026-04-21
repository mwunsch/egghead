defmodule Egghead.Eval.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Egghead.Eval.Workspace
  alias Egghead.Record

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "eval_ws_#{:erlang.unique_integer([:positive])}"
      )

    System.put_env("XDG_STATE_HOME", tmp)
    on_exit(fn ->
      System.delete_env("XDG_STATE_HOME")
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "create/2" do
    test "builds the expected directory tree and manifest", %{tmp: tmp} do
      run_id = "2026-04-21-test"

      {:ok, path} =
        Workspace.create(run_id, %{
          run_id: run_id,
          task: "coding/config-1",
          roster: ["coding-creator", "coding-extender"],
          started_at: "2026-04-21T00:00:00Z"
        })

      assert path == Path.join([tmp, "egghead", "eval-workspaces", run_id])
      assert File.dir?(Path.join(path, "workspace"))
      assert File.exists?(Path.join(path, "shell.log"))

      manifest = File.read!(Path.join(path, "manifest.yml"))
      assert manifest =~ "run_id: 2026-04-21-test"
      assert manifest =~ "task: coding/config-1"
      assert manifest =~ "coding-creator"
      assert manifest =~ "status: in_progress"
    end
  end

  describe "cleanup/3" do
    setup %{tmp: tmp} do
      run_id = "2026-04-21-cleanup"
      {:ok, path} = Workspace.create(run_id, %{run_id: run_id, task: "t", roster: []})
      {:ok, path: path, tmp: tmp}
    end

    test "deletes on success with keep=false", %{path: path} do
      assert :deleted = Workspace.cleanup(path, :ok, false)
      refute File.exists?(path)
    end

    test "keeps on success with keep=true", %{path: path} do
      assert :kept = Workspace.cleanup(path, :ok, true)
      assert File.exists?(path)
    end

    test "keeps on failure regardless of flag", %{path: path} do
      assert :kept = Workspace.cleanup(path, :error, false)
      assert File.exists?(path)
    end

    test "keeps on skipped regardless of flag", %{path: path} do
      assert :kept = Workspace.cleanup(path, :skipped, false)
      assert File.exists?(path)
    end
  end

  describe "scope_record/2" do
    test "rewrites fs.read/write as path-scoped under the workspace" do
      ws = "/eval-workspaces/run-x"

      record = %Record{
        id: "coding-dev",
        class: :agent,
        meta: %{"capabilities" => ["fs.read", "fs.write", "records.read"]}
      }

      scoped = Workspace.scope_record(record, ws)
      caps = scoped.meta["capabilities"]

      # fs.read became a scoped map
      assert %{"fs.read" => %{"paths" => paths}} = Enum.find(caps, &match?(%{"fs.read" => _}, &1))
      assert paths == ["#{ws}/workspace/**"]

      # fs.write became a scoped map
      assert %{"fs.write" => %{"paths" => paths_w}} =
               Enum.find(caps, &match?(%{"fs.write" => _}, &1))

      assert paths_w == ["#{ws}/workspace/**"]

      # records.read is a bare string, passes through
      assert "records.read" in caps
    end

    test "rewrites shell.exec as cmd-scoped using the allowlist" do
      ws = "/eval-workspaces/run-y"

      record = %Record{
        id: "coding-dev",
        class: :agent,
        meta: %{"capabilities" => ["shell.exec"]}
      }

      scoped = Workspace.scope_record(record, ws)
      caps = scoped.meta["capabilities"]

      assert [%{"shell.exec" => %{"cmds" => cmds}}] = caps

      # Must include core interpreters + read-only navigation.
      assert "python3" in cmds
      assert "node" in cmds
      assert "ls" in cmds
      assert "grep" in cmds
      assert "mkdir" in cmds

      # Explicit allowlist — nothing destructive, nothing networked.
      refute "rm" in cmds
      refute "curl" in cmds
      refute "wget" in cmds
      refute "sudo" in cmds
      refute "ssh" in cmds
    end

    test "leaves records-only personas untouched" do
      record = %Record{
        id: "researcher",
        class: :agent,
        meta: %{"capabilities" => ["records.read", "records.create"]}
      }

      scoped = Workspace.scope_record(record, "/eval/ws-1")
      assert scoped.meta["capabilities"] == ["records.read", "records.create"]
    end
  end

  describe "allowed_shell_cmds/0" do
    test "returns a stable list that excludes destructive commands" do
      cmds = Workspace.allowed_shell_cmds()

      # Interpreters
      assert "python3" in cmds
      assert "node" in cmds
      assert "ruby" in cmds

      # No write-beyond-scope / networked / privileged commands
      for banned <- ["rm", "cp", "mv", "sudo", "chmod", "chown", "curl", "wget", "ssh", "scp"] do
        refute banned in cmds, "#{banned} should not be in the eval shell allowlist"
      end
    end
  end
end
