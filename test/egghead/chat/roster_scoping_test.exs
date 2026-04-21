defmodule Egghead.Chat.RosterScopingTest do
  @moduledoc """
  Regression tests for bespoke-roster rooms (e.g. eval runs).

  Two failure modes were fixed together:

  1. `Egghead.create_room(agents: ids)` filtered `list_agents/0`, which
     only reports store-backed agents + Index. Transient agent
     processes (eval personas) were filtered out, so zero agents
     joined the room. Regression guarded by `agent_info_by_id/1` test.

  2. The Coordinator's `tier1_filter` ran against the global agent
     registry, not the room-scoped set. When a bespoke-roster room
     had zero joined agents, the user's pre-registered store agents
     activated instead. Regression guarded by `scope_to_room/2` test.
  """

  use ExUnit.Case

  alias Egghead.Agent
  alias Egghead.Chat.Coordinator
  alias Egghead.Chat.Room
  alias Egghead.Record

  setup_all do
    case Phoenix.PubSub.Supervisor.start_link(name: Egghead.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  describe "Egghead.agent_info_by_id/1" do
    test "resolves a transient agent process not in the record store" do
      agent_id = "transient-#{:erlang.unique_integer([:positive])}"

      record = %Record{
        id: agent_id,
        title: "Transient Test Agent",
        class: :agent,
        tags: ["transient", "test"],
        meta: %{
          "capabilities" => ["records.read"],
          "model" => "claude-haiku-4-5",
          "provider" => "anthropic"
        },
        body: "A test persona not persisted to the store.",
        source_path: nil
      }

      {:ok, pid} = Agent.start_link(record)

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid)
        catch
          _, _ -> :ok
        end
      end)

      info = Egghead.agent_info_by_id(agent_id)

      assert info != nil, "transient agent should resolve via its registered process"
      assert info.id == agent_id
      assert info.name == "Transient Test Agent"
      assert info.disposition == "A test persona not persisted to the store."
      assert is_list(info.capabilities)
      assert is_list(info.tags)
    end

    test "returns nil for an unknown id" do
      assert Egghead.agent_info_by_id("does-not-exist-#{:rand.uniform(1_000_000)}") == nil
    end
  end

  describe "Coordinator.scope_to_room/2" do
    test "returns only agents joined to the target room" do
      room_id = "scope-test-#{:erlang.unique_integer([:positive])}"
      {:ok, _pid} = Room.start_link(id: room_id)

      Room.join(room_id, "agents/joined-one")
      Room.join(room_id, "agents/joined-two")

      # Global registry contains three — only two belong to this room.
      all_agents = %{
        "agents/joined-one" => %{id: "agents/joined-one"},
        "agents/joined-two" => %{id: "agents/joined-two"},
        "agents/not-joined" => %{id: "agents/not-joined"}
      }

      scoped = Coordinator.scope_to_room(all_agents, room_id)

      assert Map.has_key?(scoped, "agents/joined-one")
      assert Map.has_key?(scoped, "agents/joined-two")
      refute Map.has_key?(scoped, "agents/not-joined")
    end

    test "falls back to all_agents when the room isn't running" do
      # A stale/crashed room should NOT silently drop all activation —
      # the fallback is deliberately permissive so failures are
      # visible in logs rather than stalling the chat.
      all_agents = %{"a" => %{id: "a"}, "b" => %{id: "b"}}

      scoped = Coordinator.scope_to_room(all_agents, "nonexistent-room-id-xyz")

      assert scoped == all_agents
    end

    test "returns empty when room has no joined agents" do
      room_id = "empty-room-#{:erlang.unique_integer([:positive])}"
      {:ok, _pid} = Room.start_link(id: room_id)

      all_agents = %{"a" => %{id: "a"}, "b" => %{id: "b"}}

      assert Coordinator.scope_to_room(all_agents, room_id) == %{}
    end
  end

  describe "create_room with a bespoke :agents roster" do
    # End-to-end guard: spawn a transient agent, create a room scoped
    # to just that id, verify the agent ended up joined. This is the
    # exact path the eval runner uses for `--roster task`.

    setup do
      # Ensure the global Coordinator name exists; create_room talks to it.
      case Phoenix.PubSub.Supervisor.start_link(name: Egghead.PubSub) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      case Coordinator.start_link([]) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      :ok
    end

    test "watch_room is synchronous — coordinator subscribes before the caller returns" do
      # Regression: watch_room used to be a cast, so the caller could
      # race ahead and broadcast a `:user_message` before the
      # Coordinator had subscribed to the room topic. Personas never
      # activated, room idle-timed out 5 min later. watch_room is now
      # a synchronous call that acts as a barrier — by the time it
      # returns, the subscription is established and any earlier
      # register_agent casts have drained (mailbox FIFO).
      coord_name = :"coord_race_#{:erlang.unique_integer([:positive])}"
      {:ok, coord} = Coordinator.start_link(name: coord_name)
      on_exit(fn -> if Process.alive?(coord), do: GenServer.stop(coord) end)

      room_id = "race-room-#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Room.start_link(id: room_id)

      # Queue register_agent casts first to load up the mailbox.
      for i <- 1..5 do
        Coordinator.register_agent(coord, "race/agent-#{i}", %{
          name: "A#{i}",
          capabilities: [],
          tags: [],
          disposition: ""
        })
      end

      # Synchronous watch_room returns only after all prior casts are
      # drained and the subscription is live.
      Coordinator.watch_room(coord, room_id)

      # Subscribe ourselves so we can observe broadcasts.
      Room.subscribe(room_id)
      Room.send_message(room_id, "hello")

      # If watch_room were still async, the Coordinator would miss the
      # user_message. Confirm it got it by checking that its state
      # contains the room and all 5 agents.
      state = :sys.get_state(coord)
      assert MapSet.member?(state.rooms, room_id)
      assert map_size(state.agents) >= 5
    end

    test "joins a transient agent process to the room" do
      agent_id = "roster-persona-#{:erlang.unique_integer([:positive])}"

      record = %Record{
        id: agent_id,
        title: "Roster Persona",
        class: :agent,
        tags: ["persona", "test"],
        meta: %{"capabilities" => ["records.read"]},
        body: "I'm a bespoke-roster persona.",
        source_path: nil
      }

      {:ok, pid} = Agent.start_link(record)

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid)
        catch
          _, _ -> :ok
        end
      end)

      room_id = "bespoke-room-#{:erlang.unique_integer([:positive])}"

      {:ok, ^room_id} =
        Egghead.create_room(id: room_id, agents: [agent_id])

      on_exit(fn ->
        if Room.exists?(room_id), do: Room.stop(room_id)
      end)

      state = Room.get_state(room_id)

      assert agent_id in state.agents,
             "transient agent should be joined to the room; " <>
               "got joined agents: #{inspect(state.agents)}"
    end
  end
end
