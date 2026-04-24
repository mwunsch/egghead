defmodule Egghead.Eval.CapabilityCheckTest do
  use ExUnit.Case, async: true

  alias Egghead.Eval.{CapabilityCheck, Task}
  alias Egghead.Record

  defp agent(id, caps) do
    %Record{id: id, class: :agent, meta: %{"capabilities" => caps}}
  end

  defp task(required) do
    %Task{
      id: "t",
      category: :research,
      milestones: [],
      prompt: "",
      required_capabilities: required
    }
  end

  test "passes when one agent covers all required verbs" do
    t = task(["records.read"])
    roster = [agent("a", ["records.read", "records.create"])]

    assert :ok = CapabilityCheck.check(t, roster)
  end

  test "passes when union of roster covers required" do
    t = task(["records.read", "fs.write", "proc.exec"])

    roster = [
      agent("a", ["records.read"]),
      agent("b", ["fs.write"]),
      agent("c", ["proc.exec"])
    ]

    assert :ok = CapabilityCheck.check(t, roster)
  end

  test "fails with named missing verbs" do
    t = task(["records.read", "fs.write", "proc.exec"])
    roster = [agent("a", ["records.read"])]

    assert {:error, {:missing, missing}} = CapabilityCheck.check(t, roster)
    assert "fs.write" in missing
    assert "proc.exec" in missing
    refute "records.read" in missing
  end

  test "no requirements means anything passes (even empty roster)" do
    t = task([])
    assert :ok = CapabilityCheck.check(t, [])
  end

  test "accepts scoped capability maps in frontmatter" do
    # Real frontmatter occasionally encodes scoped grants as maps,
    # e.g. `net.get{hosts=[*]}` parses to `%{"net.get" => %{"hosts" => ["*"]}}`.
    # Gating should look at the verb key only; scope is checked at dispatch.
    t = task(["net.get", "records.read"])

    roster = [
      %Record{
        id: "scoped",
        class: :agent,
        meta: %{
          "capabilities" => [
            %{"net.get" => %{"hosts" => ["*"]}},
            "records.read"
          ]
        }
      }
    ]

    assert :ok = CapabilityCheck.check(t, roster)
  end

  test "accepts atom-keyed capability entries" do
    t = task(["records.read"])
    roster = [%Record{id: "a", class: :agent, meta: %{"capabilities" => [:"records.read"]}}]

    assert :ok = CapabilityCheck.check(t, roster)
  end

  test "format_error lists missing verbs and per-agent held capabilities" do
    roster = [agent("a", ["records.read"])]
    text = CapabilityCheck.format_error({:missing, ["fs.write"]}, roster)

    assert text =~ "Missing: fs.write"
    assert text =~ "a: records.read"
  end
end
