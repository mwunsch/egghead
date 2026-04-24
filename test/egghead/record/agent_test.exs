defmodule Egghead.Record.AgentTest do
  @moduledoc """
  Unit tests for `Egghead.Record.Agent`, the projection from an
  `:agent`-class record into typed agent config.
  """

  use ExUnit.Case, async: true

  alias Egghead.Record
  alias Egghead.Record.Agent, as: Projection

  defp record(opts) do
    base = %Record{
      id: opts[:id] || "agents/test",
      title: opts[:title] || "Test Agent",
      body: opts[:body] || "Be helpful.",
      class: :agent,
      tags: opts[:tags] || [],
      meta: opts[:meta] || %{}
    }

    base
  end

  describe "from/1" do
    test "fills defaults when meta is empty" do
      config = Projection.from(record(meta: %{}))

      assert config.id == "agents/test"
      assert config.name == "Test Agent"
      assert config.disposition == "Be helpful."
      assert [%Egghead.Capability.Grant{resource: :records, verb: :read}] = config.capabilities
      assert config.max_tokens == 4096
      assert config.context_threshold == 0.70
      assert is_binary(config.model)
    end

    test "reads all known meta keys when set" do
      config =
        Projection.from(
          record(
            meta: %{
              "model" => "anthropic/claude-opus-4-7",
              "thinking" => "enabled",
              "max_tokens" => 8192,
              "temperature" => 0.3,
              "context_threshold" => 0.9,
              "capabilities" => ["records.read", "records.create"]
            }
          )
        )

      assert config.model == "anthropic/claude-opus-4-7"
      assert config.thinking == "enabled"
      assert config.max_tokens == 8192
      assert config.temperature == 0.3
      assert config.context_threshold == 0.9
      assert length(config.capabilities) == 2
    end

    test "joins provider and model when model is unqualified" do
      config =
        Projection.from(
          record(
            meta: %{
              "model" => "claude-sonnet-4-6",
              "provider" => "anthropic"
            }
          )
        )

      assert config.model == "anthropic/claude-sonnet-4-6"
    end

    test "excludes the 'agent' tag from tags list" do
      config = Projection.from(record(tags: ["agent", "research", "synthesis"]))
      assert config.tags == ["research", "synthesis"]
    end

    test "falls back to id when title is missing" do
      rec = %Record{id: "agents/unnamed", class: :agent, body: "", meta: %{}}
      config = Projection.from(rec)
      assert config.name == "agents/unnamed"
    end

    test "tolerates malformed numeric meta gracefully" do
      config =
        Projection.from(
          record(
            meta: %{
              "max_tokens" => "not-a-number",
              "temperature" => "nonsense"
            }
          )
        )

      # Falls back to defaults rather than crashing.
      assert config.max_tokens == 4096
      assert config.temperature == nil
    end

    test "reads context_window override from frontmatter" do
      # Escape hatch for local-model users whose endpoint doesn't
      # advertise a ceiling (Ollama, LM Studio).
      config = Projection.from(record(meta: %{"context_window" => 32768}))
      assert config.context_window == 32768
    end

    test "context_window defaults to nil when absent" do
      config = Projection.from(record(meta: %{}))
      assert config.context_window == nil
    end

    test "tolerates malformed context_window gracefully" do
      config = Projection.from(record(meta: %{"context_window" => "not-a-number"}))
      assert config.context_window == nil
    end
  end

  describe "access: shortcut" do
    alias Egghead.Capability.Grant

    test "access: r expands to records.read" do
      config = Projection.from(record(meta: %{"access" => "r"}))
      assert [%Grant{resource: :records, verb: :read}] = config.capabilities
    end

    test "access: w expands to records.create + records.update (write-blind)" do
      config = Projection.from(record(meta: %{"access" => "w"}))

      verbs =
        config.capabilities
        |> Enum.map(&{&1.resource, &1.verb})
        |> Enum.sort()

      assert verbs == [{:records, :create}, {:records, :update}]
    end

    test "access: rw expands to read + create + update (no delete)" do
      config = Projection.from(record(meta: %{"access" => "rw"}))

      verbs =
        config.capabilities
        |> Enum.map(&{&1.resource, &1.verb})
        |> Enum.sort()

      assert verbs == [{:records, :create}, {:records, :read}, {:records, :update}]
      refute Enum.any?(config.capabilities, &(&1.verb == :delete))
    end

    test "access unions with explicit capabilities, no duplicates" do
      config =
        Projection.from(
          record(
            meta: %{
              "access" => "r",
              "capabilities" => ["records.read", "net.get"]
            }
          )
        )

      verbs =
        config.capabilities
        |> Enum.map(&{&1.resource, &1.verb})
        |> Enum.sort()

      assert verbs == [{:net, :get}, {:records, :read}]
    end

    test "access normalizes whitespace and case" do
      config = Projection.from(record(meta: %{"access" => " RW "}))

      verbs =
        config.capabilities
        |> Enum.map(&{&1.resource, &1.verb})
        |> Enum.sort()

      assert verbs == [{:records, :create}, {:records, :read}, {:records, :update}]
    end

    test "invalid access value drops the shortcut; explicit caps still apply" do
      # Invalid access + explicit capabilities → explicit capabilities
      # survive (access is lenient at load-time, strict at authoring time).
      config =
        Projection.from(
          record(
            meta: %{
              "access" => "xyz",
              "capabilities" => ["net.get"]
            }
          )
        )

      assert [%Grant{resource: :net, verb: :get}] = config.capabilities
    end

    test "invalid access alone falls back to empty grants (no default injection)" do
      # The presence of the access key — even if invalid — opts the agent
      # out of the default records.read. This mirrors how an explicit
      # `capabilities: []` also opts out. The user is declaring intent.
      config = Projection.from(record(meta: %{"access" => "xyz"}))
      assert config.capabilities == []
    end
  end

  describe "sandbox: shortcut" do
    alias Egghead.Capability.Grant

    test "sandbox path expands to fs.read + fs.write + proc.exec with `in:` scope" do
      config = Projection.from(record(meta: %{"sandbox" => "~/projects/foo"}))

      grants = Enum.sort_by(config.capabilities, &{&1.resource, &1.verb})

      assert [
               %Grant{resource: :fs, verb: :read, scope: %{in: "~/projects/foo"}},
               %Grant{resource: :fs, verb: :write, scope: %{in: "~/projects/foo"}},
               %Grant{resource: :proc, verb: :exec, scope: %{in: "~/projects/foo"}}
             ] = grants
    end

    test "sandbox does not include proc.eval or net.* (explicit opt-in required)" do
      config = Projection.from(record(meta: %{"sandbox" => "~/work"}))

      refute Enum.any?(config.capabilities, &(&1.resource == :proc and &1.verb == :eval))
      refute Enum.any?(config.capabilities, &(&1.resource == :net))
    end

    test "sandbox unions with explicit capabilities" do
      config =
        Projection.from(
          record(
            meta: %{
              "sandbox" => "~/work",
              "capabilities" => ["records.read", "proc.eval"]
            }
          )
        )

      verbs = config.capabilities |> Enum.map(&{&1.resource, &1.verb}) |> Enum.sort()

      assert verbs == [
               {:fs, :read},
               {:fs, :write},
               {:proc, :eval},
               {:proc, :exec},
               {:records, :read}
             ]
    end

    test "sandbox unions with access: (both shortcuts in one record)" do
      config =
        Projection.from(record(meta: %{"sandbox" => "~/work", "access" => "r"}))

      verbs = config.capabilities |> Enum.map(&{&1.resource, &1.verb}) |> Enum.sort()

      assert verbs == [
               {:fs, :read},
               {:fs, :write},
               {:proc, :exec},
               {:records, :read}
             ]
    end

    test "empty/nil sandbox does nothing" do
      assert Projection.from(record(meta: %{"sandbox" => ""})).capabilities == []
      # nil is handled by parse_capabilities not seeing the key at all
    end

    test "non-string sandbox is logged and dropped" do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          config = Projection.from(record(meta: %{"sandbox" => 42}))
          assert config.capabilities == []
        end)

      assert log =~ "sandbox must be a string"
    end

    test "Record.Agent.sandbox/1 returns the declared path" do
      alias Egghead.Record.Agent

      assert Agent.sandbox(record(meta: %{"sandbox" => "~/foo"})) == "~/foo"
      assert Agent.sandbox(record(meta: %{})) == nil
      assert Agent.sandbox(record(meta: %{"sandbox" => ""})) == nil
    end

    test "default records.read still applies when neither key is present" do
      config = Projection.from(record(meta: %{"model" => "anthropic/claude-haiku-4-5"}))
      assert [%Grant{resource: :records, verb: :read}] = config.capabilities
    end

    test "explicit empty capabilities yields no grants (no default)" do
      config = Projection.from(record(meta: %{"capabilities" => []}))
      assert config.capabilities == []
    end
  end

  describe "valid_access?/1" do
    test "accepts r, w, rw (with casing and whitespace)" do
      assert Projection.valid_access?("r")
      assert Projection.valid_access?("w")
      assert Projection.valid_access?("rw")
      assert Projection.valid_access?("RW")
      assert Projection.valid_access?(" rw ")
    end

    test "rejects anything else" do
      refute Projection.valid_access?("")
      refute Projection.valid_access?("rwx")
      refute Projection.valid_access?("read")
      refute Projection.valid_access?(nil)
      refute Projection.valid_access?(42)
      refute Projection.valid_access?(["r"])
    end
  end
end
