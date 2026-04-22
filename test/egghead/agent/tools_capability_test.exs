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

    test "create_record with malformed capabilities hard-fails at resolve" do
      assert {:error, msg} =
               Tools.resolve_requests(
                 "create_record",
                 %{
                   "title" => "New",
                   "body" => "...",
                   "class" => "agent",
                   "id" => "agents/new",
                   "capabilities" => ["records.reed"]
                 },
                 %{}
               )

      assert msg =~ "capabilities validation failed"
      assert msg =~ "records.reed"
      assert msg =~ "records.read"
    end

    test "create_record with malformed scope key hard-fails at resolve" do
      assert {:error, msg} =
               Tools.resolve_requests(
                 "create_record",
                 %{
                   "title" => "New",
                   "body" => "...",
                   "class" => "agent",
                   "id" => "agents/new",
                   "capabilities" => [%{"fs.write" => %{"pathz" => ["/tmp/*"]}}]
                 },
                 %{}
               )

      assert msg =~ "unknown scope key `pathz`"
      assert msg =~ "paths"
    end

    test "create_record with access: rw emits agent.grant over expanded records caps" do
      {:ok, requests} =
        Tools.resolve_requests(
          "create_record",
          %{
            "title" => "Scribe",
            "body" => "...",
            "class" => "agent",
            "id" => "agents/scribe",
            "access" => "rw"
          },
          %{}
        )

      verbs = Enum.map(requests, &{&1.resource, &1.verb})
      assert {:agent, :create} in verbs
      assert {:agent, :grant} in verbs

      grant_req = Enum.find(requests, &(&1.verb == :grant))

      granted_verbs =
        grant_req.scope.granted
        |> Enum.map(&{&1.resource, &1.verb})
        |> Enum.sort()

      assert granted_verbs == [{:records, :create}, {:records, :read}, {:records, :update}]
    end

    test "create_record with access + capabilities unions grants for attenuation" do
      {:ok, requests} =
        Tools.resolve_requests(
          "create_record",
          %{
            "title" => "Mixed",
            "body" => "...",
            "class" => "agent",
            "id" => "agents/mixed",
            "access" => "r",
            "capabilities" => ["net.get"]
          },
          %{}
        )

      grant_req = Enum.find(requests, &(&1.verb == :grant))

      granted_verbs =
        grant_req.scope.granted
        |> Enum.map(&{&1.resource, &1.verb})
        |> Enum.sort()

      assert granted_verbs == [{:net, :get}, {:records, :read}]
    end

    test "create_record with invalid access short-circuits before grant check" do
      assert {:error, msg} =
               Tools.resolve_requests(
                 "create_record",
                 %{
                   "title" => "Bad",
                   "body" => "...",
                   "class" => "agent",
                   "id" => "agents/bad",
                   "access" => "xyz"
                 },
                 %{}
               )

      assert msg =~ "access:"
      assert msg =~ "xyz"
    end
  end

  describe "update_record with access: (integration with record store)" do
    # `req_update_record` looks up the target's class in the store;
    # without one, the class is nil and the tool falls through to a
    # `records.update` request (no agent-authority branch). These
    # tests stand up an in-memory store with a seeded agent record so
    # the access-handling branch is exercised end-to-end.

    alias Egghead.Index
    alias Egghead.RecordStore

    setup do
      suffix = :erlang.unique_integer([:positive])
      dir = Path.join(System.tmp_dir!(), "egghead_tcap_#{suffix}")
      File.rm_rf!(dir)
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "existing.md"), """
      ---
      id: agents/existing
      class: agent
      ---

      An existing agent.
      """)

      idx_name = :"tcap_index_#{suffix}"
      {:ok, _} = Index.start_link(db_path: ":memory:", name: idx_name)

      {:ok, _} =
        RecordStore.start_link(
          records_dir: dir,
          name: Egghead.RecordStore,
          watch: false,
          index: idx_name
        )

      :ok
    end

    test "update_record with only access: r triggers agent.grant (no silent escalation)" do
      {:ok, requests} =
        Tools.resolve_requests(
          "update_record",
          %{"id" => "agents/existing", "access" => "r"},
          %{}
        )

      verbs = Enum.map(requests, &{&1.resource, &1.verb})
      assert {:agent, :grant} in verbs
      refute {:agent, :update} in verbs

      grant_req = Enum.find(requests, &(&1.verb == :grant))
      assert [%Capability.Grant{resource: :records, verb: :read}] = grant_req.scope.granted
    end

    test "update_record with access alongside other fields emits both grant and update" do
      {:ok, requests} =
        Tools.resolve_requests(
          "update_record",
          %{
            "id" => "agents/existing",
            "access" => "rw",
            "model" => "anthropic/claude-haiku-4-5"
          },
          %{}
        )

      verbs = Enum.map(requests, &{&1.resource, &1.verb})
      assert {:agent, :grant} in verbs
      assert {:agent, :update} in verbs
    end

    test "update_record with invalid access short-circuits before the grant request" do
      assert {:error, msg} =
               Tools.resolve_requests(
                 "update_record",
                 %{"id" => "agents/existing", "access" => "rwx"},
                 %{}
               )

      assert msg =~ "access:"
      assert msg =~ "rwx"
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
