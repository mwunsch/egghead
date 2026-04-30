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

    test "parses compact spec form for a single-host scope" do
      grants = Capability.parse("net.get{hosts=[api.openai.com]}")
      assert [%Grant{resource: :net, verb: :get, scope: %{hosts: ["api.openai.com"]}}] = grants
    end

    test "parses compact spec form with multiple hosts" do
      grants = Capability.parse("net.get{hosts=[*.github.com,api.openai.com]}")

      assert [%Grant{resource: :net, verb: :get, scope: %{hosts: hosts}}] = grants
      assert "*.github.com" in hosts
      assert "api.openai.com" in hosts
    end

    test "parses compact spec form with multiple scope keys" do
      grants = Capability.parse("proc.exec{cmds=[rg,jq],in=~/Work}")

      assert [%Grant{resource: :proc, verb: :exec, scope: scope}] = grants
      assert scope.cmds == ["rg", "jq"]
      assert scope.in == "~/Work"
    end

    test "tokenizer respects {} and [] (commas inside don't split tokens)" do
      grants = Capability.parse("records.read net.get{hosts=[a,b,c]} agent.create")
      kinds = Enum.map(grants, &{&1.resource, &1.verb})
      assert {:records, :read} in kinds
      assert {:agent, :create} in kinds

      [net_grant] = Enum.filter(grants, fn g -> g.resource == :net end)
      assert net_grant.scope.hosts == ["a", "b", "c"]
    end

    test "merges compact-spec and map-style grants for the same resource.verb" do
      grants =
        Capability.parse([
          "net.get{hosts=[*.github.com]}",
          %{"net.get" => %{"hosts" => ["api.openai.com"]}}
        ])

      assert [%Grant{resource: :net, verb: :get, scope: %{hosts: hosts}}] = grants
      assert "*.github.com" in hosts
      assert "api.openai.com" in hosts
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

    test "proc.exec matches exact cmd" do
      grants = Capability.parse([%{"proc.exec" => %{"cmds" => ["rg", "jq"]}}])

      assert :ok =
               Capability.check(grants, %Request{
                 resource: :proc,
                 verb: :exec,
                 scope: %{cmd: "rg"}
               })

      assert {:denied, %Denial{code: :scope_violation}} =
               Capability.check(grants, %Request{
                 resource: :proc,
                 verb: :exec,
                 scope: %{cmd: "curl"}
               })
    end

    test "shell.exec is accepted as a deprecated alias for proc.exec" do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          grants = Capability.parse([%{"shell.exec" => %{"cmds" => ["rg"]}}])

          # Alias resolves to :proc and still matches a :proc request.
          assert :ok =
                   Capability.check(grants, %Request{
                     resource: :proc,
                     verb: :exec,
                     scope: %{cmd: "rg"}
                   })
        end)

      assert log =~ "deprecated alias"
      assert log =~ "proc.exec"
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

    test "denies agent.delete with target == caller" do
      grants = Capability.parse(["agent.delete"])

      request = %Request{
        resource: :agent,
        verb: :delete,
        scope: %{id: "agents/alpha"},
        tool: "delete_record"
      }

      ctx = %{agent_id: "agents/alpha"}
      assert {:denied, %Denial{code: :self_modification}} = Capability.check(grants, request, ctx)
    end

    test "allows agent.delete on a different agent" do
      grants = Capability.parse(["agent.delete"])

      request = %Request{
        resource: :agent,
        verb: :delete,
        scope: %{id: "agents/beta"},
        tool: "delete_record"
      }

      ctx = %{agent_id: "agents/alpha"}
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

  describe "parse_grant_spec/1 and grant_to_spec/1" do
    test "bare resource.verb parses as a string" do
      assert {:ok, "records.read"} = Capability.parse_grant_spec("records.read")
    end

    test "scoped grant parses to a map" do
      assert {:ok, %{"net.get" => %{"hosts" => ["*.github.com"]}}} =
               Capability.parse_grant_spec("net.get{hosts=[*.github.com]}")
    end

    test "multiple scope pairs" do
      {:ok, parsed} =
        Capability.parse_grant_spec("proc.exec{cmds=[rg,jq],patterns=[git:*]}")

      assert %{"proc.exec" => scope} = parsed
      assert scope["cmds"] == ["rg", "jq"]
      assert scope["patterns"] == ["git:*"]
    end

    test "empty spec errors" do
      assert {:error, _} = Capability.parse_grant_spec("")
    end

    test "malformed scope (missing }) errors" do
      assert {:error, _} = Capability.parse_grant_spec("net.get{hosts=[x]")
    end

    test "grant_to_spec/1 round-trips bare grants" do
      [grant] = Capability.parse(["records.read"])
      assert Capability.grant_to_spec(grant) == "records.read"
    end

    test "grant_to_spec/1 round-trips scoped grants" do
      [grant] = Capability.parse([%{"net.get" => %{"hosts" => ["*.github.com"]}}])
      spec = Capability.grant_to_spec(grant)
      assert spec =~ "net.get{"
      assert spec =~ "hosts="
      assert spec =~ "*.github.com"
    end
  end

  describe "hoisted `in:` sandbox" do
    test "grant with explicit `in:` allows paths under the root" do
      grants = Capability.parse([%{"fs.read" => %{"in" => "/tmp/ws"}}])

      req = %Request{resource: :fs, verb: :read, scope: %{path: "/tmp/ws/file.md"}}

      assert :ok = Capability.check(grants, req)
    end

    test "grant with `in:` denies paths outside the root" do
      grants = Capability.parse([%{"fs.read" => %{"in" => "/tmp/ws"}}])

      req = %Request{resource: :fs, verb: :read, scope: %{path: "/etc/hosts"}}

      assert {:denied, %Denial{code: :scope_violation}} = Capability.check(grants, req)
    end

    test "bare `fs.read` grant inherits `in:` from ctx[:agent_sandbox]" do
      # Bare grant in frontmatter + agent-level sandbox → the grant's
      # effective `in:` is hoisted from the agent, no explicit scope needed.
      grants = Capability.parse(["fs.read"])

      req = %Request{resource: :fs, verb: :read, scope: %{path: "/tmp/ws/file.md"}}

      assert :ok = Capability.check(grants, req, %{agent_sandbox: "/tmp/ws"})
    end

    test "bare grant inherits from config_sandbox when agent_sandbox is nil" do
      # This is the "add one line to config, every agent works" ergonomic:
      # an agent with plain `fs.read` in its frontmatter + config `sandbox:`
      # → the config root becomes the agent's effective fence.
      grants = Capability.parse(["fs.read"])

      req = %Request{resource: :fs, verb: :read, scope: %{path: "/tmp/ws/file.md"}}

      assert :ok = Capability.check(grants, req, %{config_sandbox: "/tmp/ws"})
    end

    test "agent_sandbox takes precedence over config_sandbox" do
      # When both are set, agent is deeper → wins. A narrower agent root
      # must restrict beyond the config ceiling (widening is not permitted
      # in principle; that subpath check is a follow-up).
      grants = Capability.parse(["fs.read"])

      # Request inside agent sandbox but outside config — in this pass
      # we allow it because agent beats config. Follow-up work may tighten.
      req = %Request{resource: :fs, verb: :read, scope: %{path: "/tmp/agent/x"}}

      assert :ok =
               Capability.check(grants, req, %{
                 agent_sandbox: "/tmp/agent",
                 config_sandbox: "/tmp/config"
               })
    end

    test "no hoist + no explicit `in:` + no `paths:` denies (inert external grant)" do
      grants = Capability.parse(["fs.read"])
      req = %Request{resource: :fs, verb: :read, scope: %{path: "/anything"}}

      assert {:denied, %Denial{code: :scope_violation}} = Capability.check(grants, req)
    end

    test "explicit grant `in:` overrides hoisted ctx" do
      # Grant has its own narrower fence — the ctx-level hoist doesn't
      # replace it. The matcher uses the more specific root.
      grants = Capability.parse([%{"fs.read" => %{"in" => "/tmp/narrow"}}])

      req = %Request{resource: :fs, verb: :read, scope: %{path: "/tmp/wider/x"}}

      assert {:denied, %Denial{code: :scope_violation}} =
               Capability.check(grants, req, %{agent_sandbox: "/tmp/wider"})
    end

    test "relative `paths:` are joined to `in:` and matched" do
      grants = Capability.parse([%{"fs.read" => %{"in" => "/tmp/ws", "paths" => ["./lib/**"]}}])

      req_inside = %Request{resource: :fs, verb: :read, scope: %{path: "/tmp/ws/lib/foo.ex"}}
      req_outside = %Request{resource: :fs, verb: :read, scope: %{path: "/tmp/ws/test/foo.ex"}}

      assert :ok = Capability.check(grants, req_inside)
      assert {:denied, _} = Capability.check(grants, req_outside)
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
