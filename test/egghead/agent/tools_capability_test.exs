defmodule Egghead.Agent.ToolsCapabilityTest do
  @moduledoc """
  Unit tests for the capability gate in `Egghead.Agent.Tools`.
  """

  use ExUnit.Case, async: false

  alias Egghead.Agent.Tools
  alias Egghead.Capability
  alias Egghead.Capability.Denial
  alias Egghead.Capability.Request

  describe "resolve_requests/3" do
    test "search_records → records.read" do
      {:ok, [%Request{resource: :records, verb: :read}]} =
        Tools.resolve_requests("search_records", %{"query" => "x"}, %{})
    end

    test "get_record → records.read" do
      {:ok, [%Request{resource: :records, verb: :read}]} =
        Tools.resolve_requests("get_record", %{"id" => "x"}, %{})
    end

    test "create_record with non-agent class → records.create" do
      {:ok, [%Request{resource: :records, verb: :create, scope: scope}]} =
        Tools.resolve_requests(
          "create_record",
          %{"title" => "x", "body" => "y", "class" => "durable"},
          %{}
        )

      assert scope.class == "durable"
    end

    test "create_record with class: agent → agent.create only (no capabilities)" do
      {:ok, [%Request{resource: :agent, verb: :create}]} =
        Tools.resolve_requests(
          "create_record",
          %{"title" => "New", "body" => "...", "class" => "agent", "id" => "agents/new"},
          %{}
        )
    end

    test "create_record with class: agent AND capabilities → agent.create + agent.grant" do
      {:ok, requests} =
        Tools.resolve_requests(
          "create_record",
          %{
            "title" => "New",
            "body" => "...",
            "class" => "agent",
            "id" => "agents/new",
            "capabilities" => ["records.read"]
          },
          %{}
        )

      verbs = Enum.map(requests, &{&1.resource, &1.verb})
      assert {:agent, :create} in verbs
      assert {:agent, :grant} in verbs

      grant_req = Enum.find(requests, &(&1.verb == :grant))
      assert [%Capability.Grant{resource: :records, verb: :read}] = grant_req.scope.granted
    end

    test "create_record with arbitrary agent meta fields alongside capabilities" do
      {:ok, requests} =
        Tools.resolve_requests(
          "create_record",
          %{
            "title" => "New",
            "body" => "...",
            "class" => "agent",
            "id" => "agents/new",
            "model" => "anthropic/claude-sonnet-4-6",
            "capabilities" => ["records.read"]
          },
          %{}
        )

      verbs = Enum.map(requests, &{&1.resource, &1.verb})
      assert {:agent, :create} in verbs
      assert {:agent, :grant} in verbs

      grant_req = Enum.find(requests, &(&1.verb == :grant))
      assert [%Capability.Grant{resource: :records, verb: :read}] = grant_req.scope.granted
    end

    test "unknown tool" do
      assert {:error, :unknown_tool} = Tools.resolve_requests("nope", %{}, %{})
    end
  end

  describe "execute/3 denies" do
    test "when the agent has no capability for the tool" do
      grants = Capability.parse(["records.read"])

      # update_record requires one of records.update / agent.update / agent.grant.
      # offers_on would hide it, but we're calling execute directly.
      # Target is unknown → treated as non-agent → routes to records.update.
      assert {:denied, %Denial{code: :capability_absent, tool: "update_record"}} =
               Tools.execute("update_record", %{"id" => "design/x", "body" => "y"}, %{
                 capabilities: grants,
                 agent_id: "agents/scout"
               })
    end
  end
end
