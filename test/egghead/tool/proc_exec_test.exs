defmodule Egghead.Tool.ProcExecTest do
  use ExUnit.Case, async: true

  alias Egghead.Tool.ProcExec

  describe "request_for/1" do
    test "builds a proc.exec request with cmd + full argv in scope" do
      {:ok, [req]} = ProcExec.request_for(%{"cmd" => "rg", "args" => ["foo", "src/"]})
      assert req.resource == :proc
      assert req.verb == :exec
      assert req.scope.cmd == "rg"
      assert req.scope.argv == ["rg", "foo", "src/"]
    end
  end

  describe "run/2 — happy path" do
    test "echo works and returns stdout" do
      assert {:ok, "hello\n"} = ProcExec.run(%{"cmd" => "echo", "args" => ["hello"]})
    end

    test "combines stderr into output" do
      {status, text} =
        ProcExec.run(%{
          "cmd" => "sh",
          "args" => ["-c", "echo out; echo err >&2"]
        })

      assert status == :ok
      assert text =~ "out"
      assert text =~ "err"
    end
  end

  describe "run/2 — error cases" do
    test "unknown command" do
      assert {:error, msg} =
               ProcExec.run(%{"cmd" => "definitely-not-a-real-command-xxxx"})

      assert msg =~ "not found"
    end

    test "non-zero exit surfaces as :error with output" do
      {:error, text} = ProcExec.run(%{"cmd" => "sh", "args" => ["-c", "exit 42"]})
      assert text =~ "exit 42"
    end
  end

  describe "run/2 — timeout" do
    test "slow command gets killed" do
      assert {:error, msg} =
               ProcExec.run(
                 %{"cmd" => "sleep", "args" => ["10"], "timeout" => 200},
                 []
               )

      assert msg =~ "timed out"
    end
  end

  describe "run/2 — streaming" do
    test "on_output callback receives chunks" do
      pid = self()

      ProcExec.run(
        %{"cmd" => "sh", "args" => ["-c", "echo first; echo second"]},
        on_output: fn chunk -> send(pid, {:chunk, chunk}) end
      )

      assert_receive {:chunk, chunk}, 2000
      assert is_binary(chunk)
    end
  end

  describe "run/2 — sandboxed" do
    alias Egghead.Sandbox.Profile

    setup do
      ws =
        Path.join(
          System.tmp_dir!(),
          "egghead-proc-exec-test-#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(ws)
      on_exit(fn -> File.rm_rf(ws) end)
      %{workspace: ws}
    end

    test "runs a command inside the fence", %{workspace: ws} do
      profile = Profile.from_root(ws, net: false)

      assert {:ok, text} =
               ProcExec.run(
                 %{"cmd" => "sh", "args" => ["-c", "pwd && echo ok > marker"]},
                 cwd: ws,
                 sandbox: profile
               )

      assert text =~ ws
      assert File.read!(Path.join(ws, "marker")) == "ok\n"
    end

    test "subprocess cannot escape the fence", %{workspace: ws} do
      profile = Profile.from_root(ws, net: false)

      escape = "/tmp/egghead-proc-exec-escape-#{:erlang.unique_integer([:positive])}"
      on_exit(fn -> File.rm(escape) end)

      _ =
        ProcExec.run(
          %{"cmd" => "sh", "args" => ["-c", "echo pwned > #{escape} 2>&1; echo done"]},
          cwd: ws,
          sandbox: profile
        )

      refute File.exists?(escape)
    end
  end
end
