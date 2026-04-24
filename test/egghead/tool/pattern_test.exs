defmodule Egghead.Tool.PatternTest do
  use ExUnit.Case, async: true

  alias Egghead.Tool.Pattern

  describe "cmds allowlist" do
    test "exact argv[0] match allows any args" do
      assert :ok = Pattern.check(["rg", "foo", "src/"], %{cmds: ["rg", "jq"]})
      assert :ok = Pattern.check(["jq"], %{cmds: ["rg", "jq"]})
    end

    test "unknown argv[0] denies" do
      assert {:scope_violation, _} = Pattern.check(["curl", "..."], %{cmds: ["rg"]})
    end
  end

  describe "patterns — literal match" do
    test "exact invocation matches literal pattern" do
      assert :ok = Pattern.check(["npm", "test"], %{patterns: ["npm test"]})
    end

    test "different invocation denies" do
      assert {:scope_violation, _} = Pattern.check(["npm", "install"], %{patterns: ["npm test"]})
    end
  end

  describe "patterns — glob" do
    test "`git log *` matches git log with any args" do
      assert :ok = Pattern.check(["git", "log"], %{patterns: ["git log *"]})
      assert :ok = Pattern.check(["git", "log", "--oneline"], %{patterns: ["git log *"]})
    end

    test "`git log *` does not match other git subcommands" do
      assert {:scope_violation, _} = Pattern.check(["git", "push"], %{patterns: ["git log *"]})
    end
  end

  describe "patterns — colon shorthand" do
    test "`git:*` matches any git subcommand" do
      assert :ok = Pattern.check(["git", "status"], %{patterns: ["git:*"]})
      assert :ok = Pattern.check(["git", "log", "--oneline"], %{patterns: ["git:*"]})
    end

    test "`git:*` doesn't match other commands" do
      assert {:scope_violation, _} = Pattern.check(["npm", "test"], %{patterns: ["git:*"]})
    end
  end

  describe "patterns — universal wildcard" do
    test "`*` matches anything" do
      assert :ok = Pattern.check(["anything", "goes", "--here"], %{patterns: ["*"]})
    end
  end

  describe "empty grant" do
    test "no in, no cmds, no patterns denies everything" do
      assert {:scope_violation, msg} = Pattern.check(["ls"], %{})
      assert msg =~ "no `in:`, `cmds:`, or `patterns:`"
    end

    test "bare `in:` (kernel-fence only) allows any argv" do
      # This is the shape the `sandbox:` sugar expands to for proc.exec:
      # `{ in: ~/foo }` with no cmds/patterns. The kernel sandbox is the
      # fence — any command, fenced to the root. Without this, the
      # sandbox: sugar would be inert for proc.exec.
      assert :ok = Pattern.check(["ls", "-la"], %{in: "/tmp/ws"})
      assert :ok = Pattern.check(["git", "status"], %{in: "/tmp/ws"})
      assert :ok = Pattern.check(["anything", "really"], %{in: "/tmp/ws"})
    end

    test "`in:` + `cmds:` still honors the cmds allowlist" do
      # When both are present, cmds narrows — a cmd not in the list is
      # denied even though the sandbox fence would contain it. Explicit
      # argv narrowing wins over the implicit any-argv rule.
      assert :ok = Pattern.check(["git", "status"], %{in: "/tmp/ws", cmds: ["git"]})

      assert {:scope_violation, _} =
               Pattern.check(["rm", "-rf"], %{in: "/tmp/ws", cmds: ["git"]})
    end
  end

  describe "format_argv/1" do
    test "quotes args with spaces" do
      assert Pattern.format_argv(["echo", "hello world"]) == "echo 'hello world'"
    end

    test "leaves simple args alone" do
      assert Pattern.format_argv(["rg", "foo", "src/"]) == "rg foo src/"
    end
  end
end
