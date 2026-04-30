defmodule Egghead.Eval.JudgeTest do
  use ExUnit.Case, async: true

  alias Egghead.Eval.Judge

  describe "default_agent/1" do
    test "returns the built-in record loaded from priv/agents/judge.md" do
      record = Judge.default_agent()

      assert record.id == "judge"
      assert record.class == :agent
      assert record.title == "Judge"
      assert "judge" in record.tags
      assert "eval" in record.tags
      assert record.meta["capabilities"] == ["records.read"]
      assert record.meta["quiet"] == true
      assert record.meta["idle"] == true
    end

    test "omits model so the projection resolves it at spawn time" do
      record = Judge.default_agent()

      refute Map.has_key?(record.meta, "model")
    end

    test "honours an explicit model override" do
      record = Judge.default_agent(model: "anthropic/claude-opus-4-7")

      assert record.meta["model"] == "anthropic/claude-opus-4-7"
    end

    test "disposition contains MARBLE attribution guidance" do
      record = Judge.default_agent()

      assert record.body =~ "MARBLE"
      assert record.body =~ "JSON"
    end
  end
end
