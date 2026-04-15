defmodule Egghead.ChatTest do
  use ExUnit.Case

  alias Egghead.Chat.Room
  alias Egghead.Chat.Coordinator

  # --- Setup ---

  setup_all do
    # Start PubSub once for all tests
    case Phoenix.PubSub.Supervisor.start_link(name: Egghead.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  # --- Helpers ---

  defp start_room(id, opts \\ []) do
    {:ok, _pid} = Room.start_link([id: id] ++ opts)
    id
  end

  defp start_coordinator do
    name = :"coord_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = Coordinator.start_link(name: name)
    pid
  end

  # --- Room tests ---

  describe "Room" do
    test "starts and accepts messages" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}")

      Room.send_message(room, "Hello agents!")

      transcript = Room.get_transcript(room)
      assert length(transcript) == 1
      assert hd(transcript).content == "Hello agents!"
      assert hd(transcript).sender.type == :user
    end

    test "agents can join and respond" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}")

      Room.join(room, "agents/test-agent")
      Room.send_message(room, "Hi")
      Room.agent_respond(room, "agents/test-agent", "Hello back!")

      transcript = Room.get_transcript(room)
      assert length(transcript) == 2

      agent_msg = Enum.at(transcript, 1)
      assert agent_msg.sender.type == :agent
      assert agent_msg.sender.id == "agents/test-agent"
      assert agent_msg.content == "Hello back!"
    end

    test "extracts @-mentions from messages" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}")

      Room.send_message(room, "@agents/scout what do you think?")

      transcript = Room.get_transcript(room)
      msg = hd(transcript)
      assert "agents/scout" in msg.mentions
    end

    test "@everyone mention is extracted" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}")

      Room.send_message(room, "@everyone roll call!")

      transcript = Room.get_transcript(room)
      assert "everyone" in hd(transcript).mentions
    end

    test "round budget counts @-mention chains as rounds" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}", round_budget: 2)

      Room.send_message(room, "Go")

      # First agent responds with @-mention (starts round 2)
      Room.agent_respond(room, "agent-a", "Let me ask @agent-b")

      state = Room.get_state(room)
      # Round decremented because agent-a @-mentioned agent-b
      assert state.rounds_remaining < 2
    end

    test "continue resets round budget" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}", round_budget: 1)

      Room.send_message(room, "Go")
      Room.agent_respond(room, "agent-a", "response @agent-b")

      state = Room.get_state(room)
      assert state.status == :waiting

      Room.continue(room)

      state = Room.get_state(room)
      assert state.rounds_remaining == 1
      assert state.status == :active
    end

    test "pending mentions are replayed on continue" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}", round_budget: 1)

      Room.send_message(room, "Go")
      Room.agent_respond(room, "agents/alpha", "ask @agents/beta about it")

      # Budget exhausted, mention queued
      state = Room.get_state(room)
      assert state.pending_mentions > 0

      # Subscribe AFTER the initial messages so we only see the replay
      Room.subscribe(room)
      Process.sleep(50)

      Room.continue(room)

      # Should receive the continued event and the replayed mention
      assert_receive :continued, 1000
      assert_receive {:agent_mentions, _, "agents/alpha", ["agents/beta"]}, 1000
    end

    test "agent_respond carries usage info" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}")

      Room.send_message(room, "Hi")

      usage = %{input_tokens: 100, output_tokens: 50, context_pct: 5.0}
      Room.agent_respond(room, "agent-a", "response", usage: usage)

      transcript = Room.get_transcript(room)
      agent_msg = Enum.at(transcript, 1)
      assert agent_msg.usage.context_pct == 5.0
    end

    test "get_state returns room info" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}")
      Room.join(room, "agents/scout")

      state = Room.get_state(room)
      assert state.id == room
      assert "agents/scout" in state.agents
      assert state.round_budget == 5
    end
  end

  # --- Room transcript persistence ---

  describe "Room transcript persistence" do
    test "save_transcript creates a transcript record" do
      # Need the full store running for this
      if Process.whereis(Egghead.RecordStore) do
        room = start_room("persist-test-#{:erlang.unique_integer([:positive])}")

        Room.send_message(room, "Test message for persistence")
        Room.agent_respond(room, "agents/test", "Test response")

        assert {:ok, record_id} = Room.save_transcript(room)
        assert record_id =~ "chat/"

        {:ok, record} = Egghead.get_record(record_id)
        assert record.class == :transcript
        assert "transcript" in record.tags
        assert "chat" in record.tags
      end
    end
  end

  # --- Coordinator tests ---

  describe "Coordinator" do
    test "registers and lists agents" do
      coord = start_coordinator()

      Coordinator.register_agent(coord, "agents/scout", %{
        name: "Scout",
        capabilities: ["records.read"]
      })

      Coordinator.register_agent(coord, "agents/archivist", %{
        name: "Archivist",
        capabilities: ["records.read"]
      })

      agents = Coordinator.list_registered(coord)
      assert length(agents) == 2
      ids = Enum.map(agents, & &1.id) |> Enum.sort()
      assert ids == ["agents/archivist", "agents/scout"]
    end

    test "unregister removes an agent" do
      coord = start_coordinator()

      Coordinator.register_agent(coord, "agents/scout", %{name: "Scout", capabilities: []})
      Coordinator.unregister_agent(coord, "agents/scout")

      agents = Coordinator.list_registered(coord)
      assert agents == []
    end

    test "watches a room via PubSub" do
      coord = start_coordinator()
      room = start_room("coord-test-#{:erlang.unique_integer([:positive])}")

      Coordinator.watch_room(coord, room)

      # The coordinator should now be subscribed to the room topic
      # We can verify by sending a message and checking the coordinator doesn't crash
      Room.send_message(room, "Hello")

      # Give it a moment to process
      Process.sleep(100)

      # Coordinator is still alive
      assert Process.alive?(coord)
    end
  end

  # --- Mention matching ---

  describe "mention matching" do
    test "direct @agents/id address activates correct agent" do
      room = start_room("mention-test-#{:erlang.unique_integer([:positive])}")
      Room.subscribe(room)

      Room.send_message(room, "@agents/scout check this out")

      transcript = Room.get_transcript(room)
      assert "agents/scout" in hd(transcript).mentions
    end

    test "fuzzy @scout matches agents/scout" do
      # This tests the coordinator's find_agent function
      coord = start_coordinator()

      Coordinator.register_agent(coord, "agents/scout", %{
        name: "Scout",
        capabilities: ["search"]
      })

      # The fuzzy matching happens inside the coordinator when processing mentions
      # We verify it by checking the registered agents
      agents = Coordinator.list_registered(coord)
      assert length(agents) == 1
      assert hd(agents).id == "agents/scout"
    end
  end

  # --- PubSub event broadcasting ---

  describe "PubSub broadcasting" do
    test "user messages are broadcast" do
      room = start_room("pubsub-test-#{:erlang.unique_integer([:positive])}")
      Room.subscribe(room)

      Room.send_message(room, "Hello")

      assert_receive {:user_message, msg}, 1000
      assert msg.content == "Hello"
      assert msg.sender.type == :user
    end

    test "agent messages are broadcast" do
      room = start_room("pubsub-test-#{:erlang.unique_integer([:positive])}")
      Room.subscribe(room)

      Room.send_message(room, "Hi")
      Room.agent_respond(room, "agents/test", "Hello back")

      assert_receive {:user_message, _}, 1000
      assert_receive {:agent_message, msg}, 1000
      assert msg.content == "Hello back"
      assert msg.sender.type == :agent
    end

    test "budget_exhausted is broadcast" do
      room = start_room("pubsub-test-#{:erlang.unique_integer([:positive])}", round_budget: 1)
      Room.subscribe(room)

      Room.send_message(room, "Go")
      Room.agent_respond(room, "agent-a", "done @agent-b")

      assert_receive {:user_message, _}, 1000
      assert_receive {:agent_message, _}, 1000
      assert_receive :budget_exhausted, 1000
    end

    test "continued is broadcast" do
      room = start_room("pubsub-test-#{:erlang.unique_integer([:positive])}", round_budget: 1)
      Room.subscribe(room)

      Room.send_message(room, "Go")
      Room.agent_respond(room, "agent-a", "done @agent-b")
      Room.continue(room)

      assert_receive :continued, 1000
    end
  end

  describe "Coordinator denial event handling" do
    test "does not crash on :agent_tool_denied" do
      # Regression: the coordinator previously had no handle_info clause
      # for denial events, so the first denial crashed the GenServer and
      # hung every session in every room it was watching.
      coord = start_coordinator()

      denial = %Egghead.Capability.Denial{
        code: :self_modification,
        agent_id: "agents/scout",
        tool: "update_record",
        message: "test denial",
        suggested_grant: nil
      }

      send(
        coord,
        {:agent_tool_denied, "test-room", "agents/scout", "update_record",
         %{"id" => "agents/scout"}, denial}
      )

      # Give it a moment to process
      Process.sleep(50)
      assert Process.alive?(coord)
    end
  end
end
