defmodule Egghead.Tool.ShellExecTest do
  use ExUnit.Case, async: true

  alias Egghead.Tool.ShellExec

  describe "request_for/1" do
    test "builds a shell.exec request with cmd + full argv in scope" do
      {:ok, [req]} = ShellExec.request_for(%{"cmd" => "rg", "args" => ["foo", "src/"]})
      assert req.resource == :shell
      assert req.verb == :exec
      assert req.scope.cmd == "rg"
      assert req.scope.argv == ["rg", "foo", "src/"]
    end
  end

  describe "run/2 — happy path" do
    test "echo works and returns stdout" do
      assert {:ok, "hello\n"} = ShellExec.run(%{"cmd" => "echo", "args" => ["hello"]})
    end

    test "combines stderr into output" do
      {status, text} =
        ShellExec.run(%{
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
               ShellExec.run(%{"cmd" => "definitely-not-a-real-command-xxxx"})

      assert msg =~ "not found"
    end

    test "non-zero exit surfaces as :error with output" do
      {:error, text} = ShellExec.run(%{"cmd" => "sh", "args" => ["-c", "exit 42"]})
      assert text =~ "exit 42"
    end
  end

  describe "run/2 — timeout" do
    test "slow command gets killed" do
      assert {:error, msg} =
               ShellExec.run(
                 %{"cmd" => "sleep", "args" => ["10"], "timeout" => 200},
                 []
               )

      assert msg =~ "timed out"
    end
  end

  describe "run/2 — streaming" do
    test "on_output callback receives chunks" do
      pid = self()

      ShellExec.run(
        %{"cmd" => "sh", "args" => ["-c", "echo first; echo second"]},
        on_output: fn chunk -> send(pid, {:chunk, chunk}) end
      )

      assert_receive {:chunk, chunk}, 2000
      assert is_binary(chunk)
    end
  end
end
