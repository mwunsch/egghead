defmodule Egghead.Chat.CoordinatorHotReloadTest do
  @moduledoc """
  Drives the Coordinator's record-change → lifecycle coalescing
  directly, without spinning up a full RecordStore + agent supervisor.

  Each test starts a fresh Coordinator under a unique name, registers
  one or more agents in its state, watches a fresh room topic, then
  fires synthetic `{:agent_record_changed, ...}` and `{:agent_lifecycle, ...}`
  events to assert the narration that lands on the room topic.
  """

  use ExUnit.Case, async: true

  alias Egghead.Chat.Coordinator
  alias Egghead.Chat.Coordinator.AgentInfo

  setup_all do
    case Phoenix.PubSub.Supervisor.start_link(name: Egghead.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  defp start_coord do
    name = :"coord_hr_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = Coordinator.start_link(name: name)
    {name, pid}
  end

  defp watch_topic do
    room_id = "hr-#{:erlang.unique_integer([:positive])}"
    :ok = Phoenix.PubSub.subscribe(Egghead.PubSub, "room:#{room_id}")
    room_id
  end

  defp seed_agent(coord_pid, room_id, agent_id, attrs) do
    info = struct(AgentInfo, Map.merge(%{id: agent_id, name: agent_id}, attrs))

    :sys.replace_state(coord_pid, fn state ->
      agents = Map.put(state.agents, agent_id, info)
      rooms = MapSet.put(state.rooms, room_id)
      %{state | agents: agents, rooms: rooms}
    end)
  end

  defp record(id, class \\ :agent) do
    %Egghead.Record{id: id, class: class, source_path: "/tmp/test/#{id}.md"}
  end

  describe "reload" do
    # Notices for record-driven transitions identify by agent id, not
    # display name — the title may have changed in the same save and
    # using the prior display name would mislead.
    test "fires `<id> reloading…` immediately on hint, then `<id> reloaded` on :started" do
      {coord, pid} = start_coord()
      room = watch_topic()

      seed_agent(pid, room, "agents/alpha", %{
        name: "Alpha",
        model: "anthropic/claude-haiku-4-5",
        capabilities: ["records.read"]
      })

      send(pid, {:agent_record_changed, {:reloaded, record("agents/alpha")}})
      assert_receive {:system_notice, "agents/alpha reloading…"}, 500

      # Simulate the new agent re-registering with fresh metadata.
      Coordinator.register_agent(coord, "agents/alpha", %{
        name: "Alpha",
        model: "anthropic/claude-sonnet-4-6",
        capabilities: [:"records.read"]
      })

      _ = :sys.get_state(coord)

      send(pid, {:agent_lifecycle, :terminated, "agents/alpha", :shutdown, nil})
      send(pid, {:agent_lifecycle, :started, "agents/alpha", nil, nil})

      assert_receive {:system_notice,
                      "agents/alpha reloaded (model: anthropic/claude-haiku-4-5 → anthropic/claude-sonnet-4-6)"},
                     500

      refute_received {:system_notice, "Alpha left"}
      refute_received {:system_notice, "Alpha joined"}
    end

    test "title change shows up in the diff parenthetical" do
      {coord, pid} = start_coord()
      room = watch_topic()

      seed_agent(pid, room, "agents/alpha", %{name: "Alpha", model: "m"})

      send(pid, {:agent_record_changed, {:reloaded, record("agents/alpha")}})
      assert_receive {:system_notice, "agents/alpha reloading…"}

      Coordinator.register_agent(coord, "agents/alpha", %{name: "Renamed", model: "m"})
      _ = :sys.get_state(coord)

      send(pid, {:agent_lifecycle, :terminated, "agents/alpha", :shutdown, nil})
      send(pid, {:agent_lifecycle, :started, "agents/alpha", nil, nil})

      assert_receive {:system_notice, "agents/alpha reloaded (title: Alpha → Renamed)"}, 500
    end

    test "no-diff reload still narrates `<id> reloaded`" do
      {_coord, pid} = start_coord()
      room = watch_topic()

      seed_agent(pid, room, "agents/alpha", %{name: "Alpha", model: "m"})

      send(pid, {:agent_record_changed, {:reloaded, record("agents/alpha")}})
      assert_receive {:system_notice, "agents/alpha reloading…"}

      send(pid, {:agent_lifecycle, :terminated, "agents/alpha", :shutdown, nil})
      send(pid, {:agent_lifecycle, :started, "agents/alpha", nil, nil})
      assert_receive {:system_notice, "agents/alpha reloaded"}, 500
    end
  end

  describe "rename" do
    test "narrates `<old-id> became <new-id>` once, on :started for new id" do
      {coord, pid} = start_coord()
      room = watch_topic()
      seed_agent(pid, room, "agents/alpha", %{name: "Alpha"})

      send(pid, {:agent_record_changed, {:renamed, "agents/alpha", record("agents/beta")}})

      Coordinator.register_agent(coord, "agents/beta", %{name: "Beta"})
      _ = :sys.get_state(coord)

      send(pid, {:agent_lifecycle, :terminated, "agents/alpha", :shutdown, nil})
      send(pid, {:agent_lifecycle, :started, "agents/beta", nil, nil})

      assert_receive {:system_notice, "agents/alpha became agents/beta"}, 500
      refute_received {:system_notice, "Alpha left"}
      refute_received {:system_notice, "Beta joined"}
    end
  end

  describe "demote" do
    test "narrates `<id> is no longer an agent` on :terminated" do
      {_coord, pid} = start_coord()
      room = watch_topic()
      seed_agent(pid, room, "agents/alpha", %{name: "Alpha"})

      send(pid, {:agent_record_changed, {:demoted, "agents/alpha"}})
      send(pid, {:agent_lifecycle, :terminated, "agents/alpha", :shutdown, nil})

      assert_receive {:system_notice, "agents/alpha is no longer an agent"}, 500
    end
  end

  describe "remove" do
    test "narrates `<id>'s record was removed` on :terminated" do
      {_coord, pid} = start_coord()
      room = watch_topic()
      seed_agent(pid, room, "agents/alpha", %{name: "Alpha"})

      send(pid, {:agent_record_changed, {:removed, "agents/alpha"}})
      send(pid, {:agent_lifecycle, :terminated, "agents/alpha", :shutdown, nil})

      assert_receive {:system_notice, "agents/alpha's record was removed"}, 500
    end
  end

  describe "promote" do
    test "narrates `<id> joined` on :started after a :promoted hint" do
      {coord, pid} = start_coord()
      room = watch_topic()

      :sys.replace_state(pid, fn s ->
        %{s | rooms: MapSet.put(s.rooms, room)}
      end)

      send(pid, {:agent_record_changed, {:promoted, record("agents/beta")}})
      Coordinator.register_agent(coord, "agents/beta", %{name: "Beta"})
      _ = :sys.get_state(coord)

      send(pid, {:agent_lifecycle, :started, "agents/beta", nil, nil})
      # Record-driven join — identify by id, not display name.
      assert_receive {:system_notice, "agents/beta joined"}, 500
    end

    # Regression: a freshly-promoted agent must populate state.agents
    # from the inline payload alone — no register_agent cast, no live
    # process to interrogate. The pre-fix code path round-tripped via
    # :sys.get_state with a 100ms timeout, which silently dropped the
    # registration when the agent was busy in :fetch_model_info. Then
    # @-mention activation found nothing in state.agents and the
    # Coordinator logged "no agents registered, nobody to activate".
    test ":started payload populates state.agents without any register_agent cast" do
      {_coord, pid} = start_coord()
      room = watch_topic()

      :sys.replace_state(pid, fn s ->
        %{s | rooms: MapSet.put(s.rooms, room)}
      end)

      send(pid, {:agent_record_changed, {:promoted, record("agents/cassowary")}})

      info = %{
        name: "Cassowary",
        model: "anthropic/claude-opus-4-7",
        capabilities: [:read],
        tags: ["bird", "research"],
        disposition: "You are Cassowary."
      }

      send(pid, {:agent_lifecycle, :started, "agents/cassowary", nil, info})
      assert_receive {:system_notice, "agents/cassowary joined"}, 500

      state = :sys.get_state(pid)
      assert %AgentInfo{} = card = Map.get(state.agents, "agents/cassowary")
      assert card.name == "Cassowary"
      assert card.model == "anthropic/claude-opus-4-7"
      assert card.tags == ["bird", "research"]
      assert card.disposition == "You are Cassowary."
    end
  end

  describe "garden-variety lifecycle (no record change)" do
    test ":started fires `<name> joined`" do
      {coord, pid} = start_coord()
      room = watch_topic()

      :sys.replace_state(pid, fn s ->
        %{s | rooms: MapSet.put(s.rooms, room)}
      end)

      Coordinator.register_agent(coord, "agents/alpha", %{name: "Alpha"})
      _ = :sys.get_state(coord)

      send(pid, {:agent_lifecycle, :started, "agents/alpha", nil, nil})
      assert_receive {:system_notice, "Alpha joined"}
    end

    test ":terminated normal fires `<name> left` and unregisters" do
      {_coord, pid} = start_coord()
      room = watch_topic()
      seed_agent(pid, room, "agents/alpha", %{name: "Alpha"})

      send(pid, {:agent_lifecycle, :terminated, "agents/alpha", :normal, nil})
      assert_receive {:system_notice, "Alpha left"}

      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)
      refute Map.has_key?(state.agents, "agents/alpha")
    end

    test ":terminated crash fires `<name> crashed: ...` and unregisters" do
      {_coord, pid} = start_coord()
      room = watch_topic()
      seed_agent(pid, room, "agents/alpha", %{name: "Alpha"})

      send(pid, {:agent_lifecycle, :terminated, "agents/alpha", :badmatch, nil})
      assert_receive {:system_notice, "Alpha crashed: :badmatch"}

      state = :sys.get_state(pid)
      refute Map.has_key?(state.agents, "agents/alpha")
    end
  end

  describe "roster broadcast" do
    test "register_agent broadcasts {:agent_roster_changed} to every watched room" do
      {coord, pid} = start_coord()
      room1 = watch_topic()
      room2 = watch_topic()

      :sys.replace_state(pid, fn s ->
        %{s | rooms: MapSet.union(s.rooms, MapSet.new([room1, room2]))}
      end)

      Coordinator.register_agent(coord, "agents/beta", %{name: "Beta"})
      _ = :sys.get_state(coord)

      assert_receive {:agent_roster_changed}
      assert_receive {:agent_roster_changed}
    end
  end
end
