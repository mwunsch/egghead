defmodule Egghead.Eval.JudgeTest do
  use ExUnit.Case, async: true

  alias Egghead.Eval.Judge

  describe "default_agent/1" do
    test "returns a synthetic record with id 'judge' and class :agent" do
      record = Judge.default_agent()

      assert record.id == "judge"
      assert record.class == :agent
      assert record.title == "Judge"
      assert "judge" in record.tags
      assert "eval" in record.tags
      assert record.meta["capabilities"] == ["records.read"]
      assert record.meta["model"] != nil
    end

    test "honours an explicit model override" do
      record = Judge.default_agent(model: "anthropic/claude-opus-4-7")

      assert record.meta["provider"] == "anthropic"
      assert record.meta["model"] == "claude-opus-4-7"
    end

    test "accepts a bare model without provider" do
      record = Judge.default_agent(model: "custom-model")

      assert record.meta["model"] == "custom-model"
      refute Map.has_key?(record.meta, "provider")
    end

    test "disposition contains MARBLE attribution guidance" do
      record = Judge.default_agent()

      assert record.body =~ "MARBLE"
      assert record.body =~ "JSON"
    end
  end
end
