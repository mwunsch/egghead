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
  end
end
