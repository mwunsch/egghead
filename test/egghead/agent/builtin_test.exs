defmodule Egghead.Agent.BuiltinTest do
  use ExUnit.Case, async: true

  alias Egghead.Agent.Builtin
  alias Egghead.Record

  describe "all/0" do
    test "loads the built-in agents from priv/agents/" do
      records = Builtin.all()
      ids = Enum.map(records, & &1.id)

      assert "index" in ids
      assert "judge" in ids
      assert Enum.all?(records, &match?(%Record{}, &1))
      assert Enum.all?(records, &(&1.class == :agent))
    end

    test "every built-in has source_path: nil" do
      assert Enum.all?(Builtin.all(), &(&1.source_path == nil))
    end

    test "no built-in pins a model — projection resolves default at spawn" do
      Enum.each(Builtin.all(), fn record ->
        refute Map.has_key?(record.meta, "model"),
               "built-in #{record.id} should omit `model:` so the configured " <>
                 "default_model is used; otherwise updating config wouldn't " <>
                 "affect the built-in without a code change"
      end)
    end
  end

  describe "fetch/1" do
    test "returns the requested record by id" do
      assert %Record{id: "index"} = Builtin.fetch("index")
      assert %Record{id: "judge"} = Builtin.fetch("judge")
    end

    test "returns nil for an unknown id" do
      assert Builtin.fetch("does-not-exist") == nil
    end
  end

  describe "ids/0" do
    test "returns just the built-in agent ids" do
      ids = Builtin.ids()
      assert "index" in ids
      assert "judge" in ids
    end
  end

  describe "built-in property semantics" do
    test "index is quiet but not idle" do
      record = Builtin.fetch("index")
      assert record.meta["quiet"] == true
      refute Map.get(record.meta, "idle", false) == true
    end

    test "judge is quiet AND idle" do
      record = Builtin.fetch("judge")
      assert record.meta["quiet"] == true
      assert record.meta["idle"] == true
    end
  end
end
