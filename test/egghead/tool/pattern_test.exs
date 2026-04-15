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
    test "no cmds and no patterns denies everything" do
      assert {:scope_violation, msg} = Pattern.check(["ls"], %{})
      assert msg =~ "no cmds or patterns"
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
