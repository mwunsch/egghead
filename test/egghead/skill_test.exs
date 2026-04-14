defmodule Egghead.SkillTest do
  use ExUnit.Case, async: true

  alias Egghead.Record
  alias Egghead.Skill

  defp record(attrs \\ []) do
    %Record{
      id: Keyword.get(attrs, :id, "skills/test"),
      class: Keyword.get(attrs, :class, :skill),
      meta: Keyword.get(attrs, :meta, %{}),
      body: Keyword.get(attrs, :body, "Do the thing."),
      source_path: Keyword.get(attrs, :source_path, nil),
      title: nil
    }
  end

  describe "validate/1" do
    test "accepts a minimal conforming skill" do
      r = record(meta: %{"description" => "Do the thing well."})
      assert :ok = Skill.validate(r)
    end

    test "requires description" do
      r = record(meta: %{})
      assert {:error, issues} = Skill.validate(r)
      assert Enum.any?(issues, &String.contains?(&1, "description"))
    end

    test "requires non-empty body" do
      r = record(meta: %{"description" => "desc"}, body: "")
      assert {:error, issues} = Skill.validate(r)
      assert Enum.any?(issues, &String.contains?(&1, "body"))
    end

    test "name derived from id passes spec regex" do
      r = record(id: "skills/pdf-processing", meta: %{"description" => "PDFs"})
      assert :ok = Skill.validate(r)
    end

    test "rejects names with uppercase" do
      r = record(id: "skills/PDF", meta: %{"name" => "PDF", "description" => "d"})
      assert {:error, issues} = Skill.validate(r)
      assert Enum.any?(issues, &String.contains?(&1, "lowercase"))
    end

    test "rejects names with consecutive hyphens" do
      r = record(meta: %{"name" => "pdf--processing", "description" => "d"})
      assert {:error, issues} = Skill.validate(r)
      assert Enum.any?(issues, &String.contains?(&1, "lowercase alphanumeric"))
    end

    test "rejects names starting with a hyphen" do
      r = record(meta: %{"name" => "-pdf", "description" => "d"})
      assert {:error, issues} = Skill.validate(r)
      assert Enum.any?(issues, &String.contains?(&1, "lowercase alphanumeric"))
    end

    test "rejects over-long description" do
      r = record(meta: %{"description" => String.duplicate("x", 1025)})
      assert {:error, issues} = Skill.validate(r)
      assert Enum.any?(issues, &String.contains?(&1, "1024"))
    end

    test "compatibility has a length ceiling" do
      r =
        record(
          meta: %{
            "description" => "d",
            "compatibility" => String.duplicate("x", 501)
          }
        )

      assert {:error, issues} = Skill.validate(r)
      assert Enum.any?(issues, &String.contains?(&1, "500"))
    end
  end

  describe "derive_name/1" do
    test "uses the name frontmatter if present" do
      r = record(id: "skills/foo/SKILL", meta: %{"name" => "bar"})
      assert Skill.derive_name(r) == "bar"
    end

    test "falls back to id with skills/ prefix stripped" do
      r = record(id: "skills/mansplain", meta: %{})
      assert Skill.derive_name(r) == "mansplain"
    end

    test "strips the /SKILL suffix from convention paths" do
      r = record(id: "skills/pdf/SKILL", meta: %{})
      assert Skill.derive_name(r) == "pdf"
    end
  end

  describe "parse_allowed_tools/1" do
    test "splits space-separated tool patterns" do
      assert Skill.parse_allowed_tools("Bash(git:*) Bash(jq:*) Read") == [
               "Bash(git:*)",
               "Bash(jq:*)",
               "Read"
             ]
    end

    test "handles nil and empty" do
      assert Skill.parse_allowed_tools(nil) == []
      assert Skill.parse_allowed_tools("") == []
      assert Skill.parse_allowed_tools([]) == []
    end

    test "accepts a list (lenient)" do
      assert Skill.parse_allowed_tools(["Read", "Bash(ls)"]) == ["Read", "Bash(ls)"]
    end
  end
end
