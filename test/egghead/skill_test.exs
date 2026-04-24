defmodule Egghead.SkillTest do
  use ExUnit.Case, async: true

  alias Egghead.Record
  alias Egghead.Skill

  defp record(attrs) do
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

  describe "derive_requirements/1" do
    test "empty allowed-tools → no requirements" do
      r = record(meta: %{"description" => "d"})
      assert %{requests: [], unknown: [], warnings: []} = Skill.derive_requirements(r)
    end

    test "Bash(git:*) → proc.exec{patterns: [git:*]}" do
      r = record(meta: %{"description" => "d", "allowed-tools" => "Bash(git:*)"})
      %{requests: [req], unknown: []} = Skill.derive_requirements(r)
      assert req.resource == :proc
      assert req.verb == :exec
      assert req.scope.patterns == ["git:*"]
    end

    test "Read(path) → fs.read with path scope" do
      r = record(meta: %{"description" => "d", "allowed-tools" => "Read(src/**)"})
      %{requests: [req]} = Skill.derive_requirements(r)
      assert req.resource == :fs
      assert req.verb == :read
      assert req.scope.paths == ["src/**"]
    end

    test "bare Read → fs.read (no scope — broad)" do
      r = record(meta: %{"description" => "d", "allowed-tools" => "Read"})
      %{requests: [req]} = Skill.derive_requirements(r)
      assert req.resource == :fs
      assert req.verb == :read
      assert req.scope == %{}
    end

    test "WebFetch(domain:host) → net.get + net.post scoped to host" do
      r = record(meta: %{"description" => "d", "allowed-tools" => "WebFetch(domain:github.com)"})
      %{requests: reqs} = Skill.derive_requirements(r)

      assert Enum.any?(reqs, fn req ->
               req.resource == :net and req.verb == :get and
                 req.scope.hosts == ["github.com"]
             end)

      assert Enum.any?(reqs, fn req ->
               req.resource == :net and req.verb == :post
             end)
    end

    test "unknown token surfaces in :unknown" do
      r = record(meta: %{"description" => "d", "allowed-tools" => "NotARealTool(xyz)"})
      %{unknown: unknown} = Skill.derive_requirements(r)
      assert "NotARealTool(xyz)" in unknown
    end

    test "multi-token allowed-tools accumulates" do
      r =
        record(
          meta: %{
            "description" => "d",
            "allowed-tools" => "Bash(git:*) Read WebFetch"
          }
        )

      %{requests: reqs, unknown: []} = Skill.derive_requirements(r)
      # Bash + Read + WebFetch(×2 methods) = 4 requests
      assert length(reqs) >= 3
      assert Enum.any?(reqs, &(&1.resource == :proc))
      assert Enum.any?(reqs, &(&1.resource == :fs))
      assert Enum.any?(reqs, &(&1.resource == :net))
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
