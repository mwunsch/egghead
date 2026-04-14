defmodule Egghead.CapabilityTest do
  use ExUnit.Case, async: true

  alias Egghead.Capability
  alias Egghead.Capability.Denial
  alias Egghead.Capability.Grant
  alias Egghead.Capability.Matcher
  alias Egghead.Capability.Request

  describe "parse/1" do
    test "parses bare verb strings" do
      assert [%Grant{resource: :records, verb: :read, scope: %{}}] =
               Capability.parse(["records.read"])
    end

    test "parses the CRUD records verbs" do
      grants =
        Capability.parse(["records.read", "records.create", "records.update", "records.delete"])

      keys = Enum.map(grants, &{&1.resource, &1.verb})
      assert {:records, :read} in keys
      assert {:records, :create} in keys
      assert {:records, :update} in keys
      assert {:records, :delete} in keys
    end

    test "parses the agent.* verbs" do
      grants = Capability.parse(["agent.create", "agent.update", "agent.delete", "agent.grant"])
      keys = Enum.map(grants, &{&1.resource, &1.verb})
      assert {:agent, :create} in keys
      assert {:agent, :grant} in keys
    end

    test "parses scoped maps" do
      grants =
        Capability.parse([
          %{"net.get" => %{"hosts" => ["*.github.com", "api.openai.com"]}}
        ])

      assert [%Grant{resource: :net, verb: :get, scope: %{hosts: hosts}}] = grants
      assert "*.github.com" in hosts
      assert "api.openai.com" in hosts
    end

    test "drops unknown capability strings with a warning" do
      assert [] = Capability.parse(["nope.invalid"])
      assert [] = Capability.parse(["record_read"])
      assert [] = Capability.parse(["search"])
    end

    test "merges duplicate resource.verb grants additively" do
      grants =
        Capability.parse([
          %{"net.get" => %{"hosts" => ["*.github.com"]}},
          %{"net.get" => %{"hosts" => ["api.openai.com"]}}
        ])

      assert [%Grant{resource: :net, verb: :get, scope: %{hosts: hosts}}] = grants
      assert length(hosts) == 2
    end

    test "accepts comma/space separated string" do
      assert [_, _] = Capability.parse("records.read agent.create")
    end
  end

  describe "check/3 — capability_absent" do
    test "denies when no grant exists for the resource.verb" do
      grants = Capability.parse(["records.read"])
      request = %Request{resource: :net, verb: :get, scope: %{host: "example.com"}, tool: "fetch"}

      assert {:denied, %Denial{code: :capability_absent, tool: "fetch"}} =
               Capability.check(grants, request)
    end
  end

  describe "check/3 — scope_violation" do
    test "net.get denies host not in allow-list" do
      grants = Capability.parse([%{"net.get" => %{"hosts" => ["*.github.com"]}}])

      request = %Request{
        resource: :net,
        verb: :get,
        scope: %{host: "api.openai.com"},
        tool: "fetch"
      }

      assert {:denied, %Denial{code: :scope_violation, message: msg}} =
               Capability.check(grants, request)

      assert msg =~ "api.openai.com"
    end

    test "net.get allows host matching *.github.com wildcard" do
      grants = Capability.parse([%{"net.get" => %{"hosts" => ["*.github.com"]}}])
      request = %Request{resource: :net, verb: :get, scope: %{host: "api.github.com"}}

      assert :ok = Capability.check(grants, request)
    end

    test "net.get with no hosts denies everything (external resource, bare = empty)" do
      grants = [%Grant{resource: :net, verb: :get, scope: %{}}]
      request = %Request{resource: :net, verb: :get, scope: %{host: "example.com"}}

      assert {:denied, %Denial{code: :scope_violation}} = Capability.check(grants, request)
    end

    test "shell.exec matches exact cmd" do
      grants = Capability.parse([%{"shell.exec" => %{"cmds" => ["rg", "jq"]}}])

      assert :ok =
               Capability.check(grants, %Request{
                 resource: :shell,
                 verb: :exec,
                 scope: %{cmd: "rg"}
               })

      assert {:denied, %Denial{code: :scope_violation}} =
               Capability.check(grants, %Request{
                 resource: :shell,
                 verb: :exec,
                 scope: %{cmd: "curl"}
               })
    end

    test "records.update class allow-list restricts modification" do
      grants =
        Capability.parse([%{"records.update" => %{"classes" => ["deliberation", "inbox"]}}])

      allowed = %Request{
        resource: :records,
        verb: :update,
        scope: %{id: "delib/x", class: "deliberation"}
      }

      denied = %Request{
        resource: :records,
        verb: :update,
        scope: %{id: "design/y", class: "durable"}
      }

      assert :ok = Capability.check(grants, allowed)
      assert {:denied, %Denial{code: :scope_violation}} = Capability.check(grants, denied)
    end
  end

  describe "check/3 — self_modification" do
    test "denies agent.grant with target == caller" do
      grants = Capability.parse(["agent.grant"])

      request = %Request{
        resource: :agent,
        verb: :grant,
        scope: %{id: "agents/scout", granted: []},
        tool: "update_record"
      }

      ctx = %{agent_id: "agents/scout"}
      assert {:denied, %Denial{code: :self_modification}} = Capability.check(grants, request, ctx)
    end

    test "allows agent.grant on a different agent" do
      grants = Capability.parse(["agent.grant"])

      request = %Request{
        resource: :agent,
        verb: :grant,
        scope: %{id: "agents/other", granted: []},
        tool: "update_record"
      }

      ctx = %{agent_id: "agents/scout"}
      assert :ok = Capability.check(grants, request, ctx)
    end

    test "allows agent.update on self (not capabilities)" do
      grants = Capability.parse(["agent.update"])

      request = %Request{
        resource: :agent,
        verb: :update,
        scope: %{id: "agents/scout"},
        tool: "update_record"
      }

      ctx = %{agent_id: "agents/scout"}
      assert :ok = Capability.check(grants, request, ctx)
    end
  end

  describe "check/3 — attenuation" do
    test "denies when proposed grants exceed granter's authority" do
      granter = Capability.parse(["agent.grant", "records.read"])

      proposed =
        Capability.parse([%{"net.post" => %{"hosts" => ["api.example.com"]}}])

      request = %Request{
        resource: :agent,
        verb: :grant,
        scope: %{id: "agents/newbie", granted: proposed}
      }

      ctx = %{agent_id: "agents/index"}

      assert {:denied, %Denial{code: :exceeds_grantor_authority}} =
               Capability.check(granter, request, ctx)
    end

    test "allows when proposed is a subset of granter's" do
      granter =
        Capability.parse([
          "agent.grant",
          "records.read",
          %{"net.get" => %{"hosts" => ["*.github.com", "*.arxiv.org"]}}
        ])

      proposed =
        Capability.parse([
          "records.read",
          %{"net.get" => %{"hosts" => ["api.github.com"]}}
        ])

      request = %Request{
        resource: :agent,
        verb: :grant,
        scope: %{id: "agents/newbie", granted: proposed}
      }

      ctx = %{agent_id: "agents/index"}
      assert :ok = Capability.check(granter, request, ctx)
    end
  end

  describe "wildcard `*` scope" do
    test "net.get with hosts: [\"*\"] allows any host" do
      grants = Capability.parse([%{"net.get" => %{"hosts" => ["*"]}}])
      req = %Request{resource: :net, verb: :get, scope: %{host: "api.anything.com"}}
      assert :ok = Capability.check(grants, req)
    end

    test "attenuation: narrow hosts ⊆ [\"*\"]" do
      parent = Capability.parse([%{"net.get" => %{"hosts" => ["*"]}}])
      child = Capability.parse([%{"net.get" => %{"hosts" => ["api.github.com"]}}])
      assert Capability.subset?(child, parent)
    end

    test "attenuation: [\"*\"] is NOT ⊆ narrow hosts" do
      parent = Capability.parse([%{"net.get" => %{"hosts" => ["*.github.com"]}}])
      child = Capability.parse([%{"net.get" => %{"hosts" => ["*"]}}])
      refute Capability.subset?(child, parent)
    end
  end

  describe "subset?/2" do
    test "external resources: child hosts must be ⊆ parent hosts" do
      parent = Capability.parse([%{"net.get" => %{"hosts" => ["*.github.com"]}}])
      child_ok = Capability.parse([%{"net.get" => %{"hosts" => ["api.github.com"]}}])
      child_bad = Capability.parse([%{"net.get" => %{"hosts" => ["api.openai.com"]}}])

      assert Capability.subset?(child_ok, parent)
      refute Capability.subset?(child_bad, parent)
    end

    test "internal resources: bare parent covers any child" do
      parent = Capability.parse(["records.read"])

      child =
        Capability.parse([%{"records.read" => %{"classes" => ["deliberation"]}}])

      assert Capability.subset?(child, parent)
    end

    test "internal resources: scoped parent requires child narrower" do
      parent = Capability.parse([%{"records.update" => %{"classes" => ["inbox"]}}])
      child_ok = Capability.parse([%{"records.update" => %{"classes" => ["inbox"]}}])

      child_bad =
        Capability.parse([%{"records.update" => %{"classes" => ["durable"]}}])

      assert Capability.subset?(child_ok, parent)
      refute Capability.subset?(child_bad, parent)
    end

    test "missing verb in parent → not subset" do
      parent = Capability.parse(["records.read"])
      child = Capability.parse(["records.create"])
      refute Capability.subset?(child, parent)
    end
  end

  describe "verbs_held/1" do
    test "returns resource.verb strings" do
      grants = Capability.parse(["records.read", %{"net.get" => %{"hosts" => ["x"]}}])
      held = Capability.verbs_held(grants)
      assert MapSet.member?(held, "records.read")
      assert MapSet.member?(held, "net.get")
    end
  end

  describe "Matcher.host_matches?/2" do
    test "exact match" do
      assert Matcher.host_matches?("api.github.com", "api.github.com")
      refute Matcher.host_matches?("api.github.com", "github.com")
    end

    test "wildcard subdomain match" do
      assert Matcher.host_matches?("api.github.com", "*.github.com")
      assert Matcher.host_matches?("github.com", "*.github.com")
      refute Matcher.host_matches?("api.notgithub.com", "*.github.com")
    end
  end

  describe "Matcher.path_matches?/2" do
    test "doublestar matches nested paths" do
      assert Matcher.path_matches?("/home/m/projects/a/b.ex", "/home/m/projects/**")
      refute Matcher.path_matches?("/home/m/other/x", "/home/m/projects/**")
    end
  end

  describe "Denial.to_tool_result/1" do
    test "formats a scope_violation actionably" do
      grants = Capability.parse([%{"net.get" => %{"hosts" => ["*.github.com"]}}])

      request = %Request{
        resource: :net,
        verb: :get,
        scope: %{host: "api.openai.com"},
        tool: "web_fetch"
      }

      {:denied, denial} = Capability.check(grants, request, %{agent_id: "agents/scout"})

      text = Denial.to_tool_result(denial)
      assert text =~ "Denied:"
      assert text =~ "scope_violation"
      assert text =~ "api.openai.com"
      assert text =~ "egghead agent grant"
    end
  end
end
