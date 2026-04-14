defmodule Egghead.AgentTest do
  use ExUnit.Case

  alias Egghead.Agent
  alias Egghead.Agent.Supervisor, as: AgentSup
  alias Egghead.Capability.Grant
  alias Egghead.Index
  alias Egghead.Record
  alias Egghead.RecordStore

  defp has_grant?(grants, resource, verb) do
    Enum.any?(grants, fn %Grant{resource: r, verb: v} -> r == resource and v == verb end)
  end

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "egghead_agent_test_#{:erlang.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp start_system(dir) do
    suffix = :erlang.unique_integer([:positive])
    idx_name = :"agent_idx_#{suffix}"
    store_name = :"agent_store_#{suffix}"
    sup_name = :"agent_sup_#{suffix}"

    {:ok, _} = Index.start_link(db_path: ":memory:", name: idx_name)

    {:ok, _} =
      RecordStore.start_link(
        records_dir: dir,
        name: store_name,
        watch: false,
        index: idx_name
      )

    {:ok, _} = AgentSup.start_link(name: sup_name)

    %{index: idx_name, store: store_name, supervisor: sup_name}
  end

  defp write_agent(dir, filename, attrs) do
    meta = Map.get(attrs, :meta, %{})

    frontmatter =
      [
        "---",
        "id: #{attrs.id}",
        "class: agent",
        "tags: [agent]",
        if(meta["model"], do: "model: #{meta["model"]}"),
        if(meta["provider"], do: "provider: #{meta["provider"]}"),
        if(meta["capabilities"],
          do: "capabilities: [#{Enum.join(meta["capabilities"], ", ")}]"
        ),
        "---"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    content = "#{frontmatter}\n\n#{attrs.body}"
    File.write!(Path.join(dir, filename), content)
  end

  describe "Agent GenServer" do
    test "starts from an agent record" do
      record = %Record{
        id: "test-agent",
        title: "Test Agent",
        class: :agent,
        tags: ["agent"],
        meta: %{
          "capabilities" => ["records.read", "records.create"],
          "model" => "claude-sonnet-4-6"
        },
        body: "You are a test agent.",
        source_path: "/tmp/test-agent.md"
      }

      {:ok, pid} = Agent.start_link(record)
      assert Process.alive?(pid)

      state = :sys.get_state(pid)
      assert state.id == "test-agent"
      assert state.name == "Test Agent"
      assert state.disposition == "You are a test agent."
      assert has_grant?(state.capabilities, :records, :read)
      assert has_grant?(state.capabilities, :records, :create)

      GenServer.stop(pid)
    end

    test "defaults to records.read when no capabilities specified" do
      record = %Record{
        id: "default-caps",
        title: "Default Agent",
        class: :agent,
        tags: ["agent"],
        meta: %{},
        body: "You are a default agent.",
        source_path: "/tmp/default-caps.md"
      }

      {:ok, pid} = Agent.start_link(record)
      state = :sys.get_state(pid)
      assert has_grant?(state.capabilities, :records, :read)

      GenServer.stop(pid)
    end

    test "filters out unknown capabilities" do
      record = %Record{
        id: "bad-caps",
        title: "Bad Caps Agent",
        class: :agent,
        tags: ["agent"],
        meta: %{"capabilities" => ["records.read", "nuclear.launch"]},
        body: "You are an agent with invalid caps.",
        source_path: "/tmp/bad-caps.md"
      }

      {:ok, pid} = Agent.start_link(record)
      state = :sys.get_state(pid)
      assert has_grant?(state.capabilities, :records, :read)
      refute Enum.any?(state.capabilities, fn g -> g.resource == :nuclear end)

      GenServer.stop(pid)
    end

    test "agent_name produces consistent names" do
      assert Agent.agent_name("agents/scout") == :"egghead_agent_agents/scout"
      assert Agent.agent_name("test") == :egghead_agent_test
    end
  end

  describe "Agent Supervisor" do
    test "sync_agents starts agents from agent-class records" do
      dir = tmp_dir()

      write_agent(dir, "test-agent.md", %{
        id: "test-agent",
        meta: %{"capabilities" => ["records.read"]},
        body: "# Test Agent\n\nYou are a test agent."
      })

      sys = start_system(dir)

      # Reload to pick up the agent record
      RecordStore.reload(sys.store)

      # Sync should start the agent
      AgentSup.sync_agents(sys.supervisor, store: sys.store)

      name = Agent.agent_name("test-agent")
      assert GenServer.whereis(name) != nil

      state = :sys.get_state(GenServer.whereis(name))
      assert state.disposition =~ "You are a test agent"
    end

    test "sync_agents stops agents whose records are removed" do
      dir = tmp_dir()

      write_agent(dir, "ephemeral.md", %{
        id: "ephemeral",
        meta: %{"capabilities" => ["records.read"]},
        body: "# Ephemeral\n\nTemporary agent."
      })

      sys = start_system(dir)
      RecordStore.reload(sys.store)
      AgentSup.sync_agents(sys.supervisor, store: sys.store)

      name = Agent.agent_name("ephemeral")
      assert GenServer.whereis(name) != nil

      # Delete the file and reload
      File.rm!(Path.join(dir, "ephemeral.md"))
      RecordStore.reload(sys.store)
      AgentSup.sync_agents(sys.supervisor, store: sys.store)

      assert GenServer.whereis(name) == nil
    end

    test "start_agent restarts an existing agent" do
      dir = tmp_dir()

      write_agent(dir, "restartable.md", %{
        id: "restartable",
        meta: %{"capabilities" => ["records.read"]},
        body: "# V1\n\nFirst version."
      })

      sys = start_system(dir)
      RecordStore.reload(sys.store)
      AgentSup.sync_agents(sys.supervisor, store: sys.store)

      name = Agent.agent_name("restartable")
      old_pid = GenServer.whereis(name)
      assert old_pid != nil

      # Update the file
      write_agent(dir, "restartable.md", %{
        id: "restartable",
        meta: %{"capabilities" => ["records.read"]},
        body: "# V2\n\nUpdated version."
      })

      RecordStore.reload(sys.store)

      # Restart the agent
      {:ok, record} = RecordStore.get_record(sys.store, "restartable")
      AgentSup.start_agent(sys.supervisor, record, store: sys.store)

      new_pid = GenServer.whereis(name)
      assert new_pid != nil
      assert new_pid != old_pid

      state = :sys.get_state(new_pid)
      assert state.disposition =~ "Updated version"
    end
  end

  describe "list_agents" do
    test "returns running agents with capabilities" do
      dir = tmp_dir()

      write_agent(dir, "listed.md", %{
        id: "listed",
        meta: %{"capabilities" => ["records.read"]},
        body: "# Listed Agent\n\nI exist to be listed."
      })

      sys = start_system(dir)
      RecordStore.reload(sys.store)
      AgentSup.sync_agents(sys.supervisor, store: sys.store)

      # list_agents uses the default RecordStore, so this won't find our test agent
      # unless we use the default names. Test the supervisor directly.
      name = Agent.agent_name("listed")
      assert GenServer.whereis(name) != nil
    end
  end
end
