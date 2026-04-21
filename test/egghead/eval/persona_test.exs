defmodule Egghead.Eval.PersonaTest do
  use ExUnit.Case, async: true

  alias Egghead.Eval.Persona

  test "fetches a MARBLE-ported research persona as an :agent record" do
    {:ok, record} = Persona.fetch("researcher-p1-1")

    assert record.id == "researcher-p1-1"
    assert record.class == :agent
    assert "persona" in record.tags
    assert "research" in record.tags
    assert "marble" in record.tags
    assert record.body =~ "researcher"
    assert record.meta["capabilities"] == ["records.read"]
    assert record.source_path == nil
  end

  test "returns :not_found for unknown persona" do
    assert {:error, :not_found} = Persona.fetch("does-not-exist")
  end

  test "fetch_all returns all records in order, or missing list" do
    {:ok, records} = Persona.fetch_all(["researcher-p1-1", "researcher-p1-2"])
    assert Enum.map(records, & &1.id) == ["researcher-p1-1", "researcher-p1-2"]

    assert {:error, {:missing, ["bad-id"]}} =
             Persona.fetch_all(["researcher-p1-1", "bad-id"])
  end
end
