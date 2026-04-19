defmodule Egghead.Capability.ValidateTest do
  use ExUnit.Case, async: true

  alias Egghead.Capability.Validate

  describe "validate/1 — empty and edge inputs" do
    test "nil is ok" do
      assert Validate.validate(nil) == :ok
    end

    test "empty list is ok" do
      assert Validate.validate([]) == :ok
    end

    test "non-list input is rejected" do
      assert {:error, [issue]} = Validate.validate(%{"records.read" => nil})
      assert issue.problem =~ "must be a list"
    end
  end

  describe "validate/1 — bare strings" do
    test "known capability passes" do
      assert Validate.validate(["records.read"]) == :ok
    end

    test "many known capabilities pass" do
      assert Validate.validate([
               "records.read",
               "records.create",
               "agent.update"
             ]) == :ok
    end

    test "unknown capability fails with a suggestion" do
      assert {:error, [issue]} = Validate.validate(["records.reed"])
      assert issue.problem =~ "unknown capability"
      assert issue.problem =~ "records.reed"
      assert issue.suggestion == "records.read"
    end

    test "unknown capability with no near-miss has no suggestion" do
      assert {:error, [issue]} = Validate.validate(["totally.unrelated"])
      assert issue.suggestion == nil
    end

    test "malformed key (no dot) produces a sensible error" do
      assert {:error, [issue]} = Validate.validate(["nodotshere"])
      assert issue.problem =~ "malformed capability"
    end

    test "empty string is rejected" do
      assert {:error, [_]} = Validate.validate([""])
    end
  end

  describe "validate/1 — scoped maps" do
    test "valid scope keys pass" do
      assert Validate.validate([%{"fs.write" => %{"paths" => ["/tmp/*"]}}]) == :ok
    end

    test "scalar id scope passes" do
      assert Validate.validate([%{"agent.grant" => %{"id" => "agents/scout"}}]) == :ok
    end

    test "empty scope is fine" do
      assert Validate.validate([%{"records.read" => %{}}]) == :ok
    end

    test "nil scope is fine" do
      assert Validate.validate([%{"records.read" => nil}]) == :ok
    end

    test "unknown scope key fails with a suggestion" do
      assert {:error, [issue]} =
               Validate.validate([%{"fs.write" => %{"pathz" => ["/tmp/*"]}}])

      assert issue.problem =~ "unknown scope key `pathz`"
      assert issue.problem =~ "fs.write"
      assert issue.suggestion == "paths"
    end

    test "unknown scope key with no near-miss has no suggestion" do
      assert {:error, [issue]} =
               Validate.validate([%{"fs.write" => %{"totally_bogus" => []}}])

      assert issue.suggestion == nil
    end

    test "wrong value type for string_list fails" do
      assert {:error, [issue]} =
               Validate.validate([%{"fs.write" => %{"paths" => "not-a-list"}}])

      assert issue.problem =~ "expected a list of strings"
    end

    test "wrong value type for string fails" do
      assert {:error, [issue]} =
               Validate.validate([%{"agent.grant" => %{"id" => ["not-a-string"]}}])

      assert issue.problem =~ "expected a string"
    end

    test "scope on capability with no scope_keys rejects any scope key" do
      # records.read accepts no scope keys at all
      assert {:error, [issue]} =
               Validate.validate([%{"records.read" => %{"paths" => ["*"]}}])

      assert issue.problem =~ "unknown scope key"
    end

    test "non-map scope is rejected" do
      assert {:error, [issue]} =
               Validate.validate([%{"fs.write" => "garbage"}])

      assert issue.problem =~ "must be a map"
    end
  end

  describe "validate/1 — mixed lists" do
    test "collects issues from multiple entries" do
      assert {:error, issues} =
               Validate.validate([
                 "records.read",
                 "records.reed",
                 %{"fs.write" => %{"pathz" => ["/tmp/*"]}}
               ])

      assert length(issues) == 2
    end

    test "non-string, non-map entries produce a clear error" do
      assert {:error, [issue]} = Validate.validate([42])
      assert issue.problem =~ "expected a capability string or a single-key map"
    end
  end

  describe "escalation_warnings/2" do
    @records_dir "/Users/test/.egghead"

    test "nil input produces no warnings" do
      assert Validate.escalation_warnings(nil, @records_dir) == []
    end

    test "empty list produces no warnings" do
      assert Validate.escalation_warnings([], @records_dir) == []
    end

    test "fs.write with records_dir prefix match flags escalation" do
      raw = [%{"fs.write" => %{"paths" => ["/Users/test/.egghead/*"]}}]
      assert [warning] = Validate.escalation_warnings(raw, @records_dir)
      assert warning =~ "fs.write"
      assert warning =~ "records_dir"
    end

    test "fs.write with wildcard path flags escalation" do
      raw = [%{"fs.write" => %{"paths" => ["*"]}}]
      assert [_] = Validate.escalation_warnings(raw, @records_dir)
    end

    test "fs.delete with records_dir coverage flags escalation" do
      raw = [%{"fs.delete" => %{"paths" => ["/Users/test/.egghead"]}}]
      assert [warning] = Validate.escalation_warnings(raw, @records_dir)
      assert warning =~ "fs.delete"
    end

    test "fs.write scoped to an unrelated path is safe" do
      raw = [%{"fs.write" => %{"paths" => ["/tmp/scratch/*"]}}]
      assert Validate.escalation_warnings(raw, @records_dir) == []
    end

    test "shell.exec with no restriction flags escalation" do
      raw = [%{"shell.exec" => %{}}]
      assert [warning] = Validate.escalation_warnings(raw, @records_dir)
      assert warning =~ "shell.exec"
      assert warning =~ "no command or pattern"
    end

    test "bare shell.exec string also flags escalation" do
      raw = ["shell.exec"]
      assert [warning] = Validate.escalation_warnings(raw, @records_dir)
      assert warning =~ "shell.exec"
    end

    test "shell.exec with cmds is bounded — no warning" do
      raw = [%{"shell.exec" => %{"cmds" => ["git", "ls"]}}]
      assert Validate.escalation_warnings(raw, @records_dir) == []
    end

    test "multiple escalations aggregate" do
      raw = [
        %{"fs.write" => %{"paths" => ["*"]}},
        %{"shell.exec" => %{}}
      ]

      warnings = Validate.escalation_warnings(raw, @records_dir)
      assert length(warnings) == 2
    end

    test "safe capabilities produce no warnings" do
      raw = [
        "records.read",
        %{"net.get" => %{"hosts" => ["*.example.com"]}},
        %{"fs.read" => %{"paths" => ["/tmp/*"]}}
      ]

      assert Validate.escalation_warnings(raw, @records_dir) == []
    end

    test "nil records_dir skips the fs.* checks" do
      raw = [%{"fs.write" => %{"paths" => ["*"]}}]
      assert Validate.escalation_warnings(raw, nil) == []
    end
  end

  describe "format_errors/1" do
    test "single issue renders with problem and suggestion" do
      {:error, issues} = Validate.validate(["records.reed"])
      formatted = Validate.format_errors(issues)

      assert formatted =~ "capabilities validation failed"
      assert formatted =~ "records.reed"
      assert formatted =~ "did you mean `records.read`"
    end

    test "multiple issues render as bullets" do
      {:error, issues} =
        Validate.validate([
          "records.reed",
          %{"fs.write" => %{"pathz" => []}}
        ])

      formatted = Validate.format_errors(issues)
      assert formatted =~ "records.reed"
      assert formatted =~ "pathz"
    end
  end
end
