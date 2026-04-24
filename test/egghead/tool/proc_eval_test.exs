defmodule Egghead.Tool.ProcEvalTest do
  use ExUnit.Case, async: true

  alias Egghead.Tool.ProcEval
  alias Egghead.Sandbox.Profile

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "egghead-proc-eval-test-#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)
    %{workspace: ws}
  end

  describe "request_for/1" do
    test "builds a proc.eval request with the full shell string" do
      {:ok, [req]} = ProcEval.request_for(%{"cmd" => "ls | head"})

      assert req.resource == :proc
      assert req.verb == :eval
      assert req.scope.cmd == "ls | head"
      assert req.tool == "proc_eval"
    end

    test "refuses empty or missing cmd" do
      assert {:error, _} = ProcEval.request_for(%{"cmd" => ""})
      assert {:error, _} = ProcEval.request_for(%{})
    end
  end

  describe "run/2 — unsandboxed (fallback)" do
    test "pipeline executes and returns combined output" do
      assert {:ok, text} = ProcEval.run(%{"cmd" => "echo one; echo two; echo three | wc -l"})
      assert text =~ "one"
      assert text =~ "two"
    end

    test "non-zero exit surfaces as :error with output" do
      assert {:error, text} = ProcEval.run(%{"cmd" => "exit 7"})
      assert text =~ "exit 7"
    end
  end

  describe "run/2 — sandboxed" do
    test "pipeline inside workspace succeeds", %{workspace: ws} do
      profile = Profile.from_root(ws, net: false)

      assert {:ok, text} =
               ProcEval.run(
                 %{"cmd" => "for i in 1 2 3; do echo item-$i > $i.txt; done && ls | sort"},
                 cwd: ws,
                 sandbox: profile
               )

      assert text =~ "1.txt"
      assert text =~ "2.txt"
      assert text =~ "3.txt"

      # Files actually landed inside the workspace (not $TMPDIR redirect).
      assert File.read!(Path.join(ws, "1.txt")) == "item-1\n"
    end

    test "shell-escape attempts fail at kernel boundary", %{workspace: ws} do
      # This is the whole point of proc.eval: the shell can construct
      # any pipeline it wants, but the kernel fences the result. A hostile
      # string can't redirect into /etc or anywhere else off-root.
      profile = Profile.from_root(ws, net: false)

      escape = "/tmp/egghead-eval-escape-#{:erlang.unique_integer([:positive])}"
      on_exit(fn -> File.rm(escape) end)

      _ =
        ProcEval.run(
          %{
            "cmd" =>
              "echo pwned > #{escape} 2>&1; cat /etc/hosts 2>&1 > #{escape}.hosts || true; echo done"
          },
          cwd: ws,
          sandbox: profile
        )

      refute File.exists?(escape)
      refute File.exists?(escape <> ".hosts")
    end

    test "read outside workspace denied even via shell substitution", %{workspace: ws} do
      profile = Profile.from_root(ws, net: false)

      {:ok, text} =
        ProcEval.run(
          %{"cmd" => "cat /etc/hosts 2>&1 || echo BLOCKED"},
          cwd: ws,
          sandbox: profile
        )

      refute text =~ "localhost",
             "sandbox leaked /etc/hosts contents via proc.eval: #{inspect(text)}"
    end
  end
end
