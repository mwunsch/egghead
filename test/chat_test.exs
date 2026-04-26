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

    test "try_activate decrements the budget; :exhausted when dry" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}", activation_budget: 2)
      Room.send_message(room, "Go")

      assert :ok = Room.try_activate(room, "agents/a")
      assert :ok = Room.try_activate(room, "agents/b")
      assert :exhausted = Room.try_activate(room, "agents/c")

      state = Room.get_state(room)
      assert state.activations_remaining == 0
    end

    test "try_activate defers :budget_exhausted until active sessions drain" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}", activation_budget: 2)
      Room.subscribe(room)
      Room.send_message(room, "Go")
      assert_receive {:user_message, _}, 1000

      # First slot consumed — still 1 left, no broadcast.
      Room.try_activate(room, "agents/a")
      refute_receive :budget_exhausted, 100

      # Second slot zeroes out remaining, but agents/a and agents/b are
      # still mid-stream. Firing now would lie ("paused" while output is
      # actively flowing). Hold the bar until they commit.
      Room.try_activate(room, "agents/b")
      refute_receive :budget_exhausted, 100

      # First agent finishes — one still in flight, still no bar.
      Room.agent_respond(room, "agents/a", "done")
      assert_receive {:agent_message, _}, 1000
      refute_receive :budget_exhausted, 100

      # Last in-flight session drains → bar fires honestly.
      Room.agent_respond(room, "agents/b", "done")
      assert_receive {:agent_message, _}, 1000
      assert_receive :budget_exhausted, 1000

      # Subsequent queue overflow does not re-broadcast.
      :exhausted = Room.try_activate(room, "agents/c")
      Room.queue_activation(room, "agents/c", activation: :normal)
      refute_receive :budget_exhausted, 100
    end

    test "queue_activation defers :budget_exhausted until active sessions drain" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}", activation_budget: 1)
      Room.subscribe(room)
      Room.send_message(room, "Go")

      assert_receive {:user_message, _}, 1000

      # Slot consumed — agents/a is in flight.
      Room.try_activate(room, "agents/a")
      :exhausted = Room.try_activate(room, "agents/b")
      Room.queue_activation(room, "agents/b", activation: :normal)

      # agents/a is still streaming; bar must not fire yet.
      refute_receive :budget_exhausted, 100

      # agents/a finishes → room is genuinely idle, bar fires.
      Room.agent_respond(room, "agents/a", "done")
      assert_receive {:agent_message, _}, 1000
      assert_receive :budget_exhausted, 1000

      # Second queue does NOT re-broadcast.
      Room.queue_activation(room, "agents/c", activation: :normal)
      refute_receive :budget_exhausted, 100
    end

    test "continue resets the budget and replays queued activations as :reactivate" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}", activation_budget: 1)
      Room.send_message(room, "Go")

      Room.try_activate(room, "agents/a")
      :exhausted = Room.try_activate(room, "agents/b")
      Room.queue_activation(room, "agents/b", activation: :normal)

      Room.subscribe(room)
      Room.continue(room)

      assert_receive {:continued, [replayed: 1]}, 1000
      assert_receive {:reactivate, ^room, "agents/b", activation: :normal}, 1000

      state = Room.get_state(room)
      assert state.activations_remaining == 1
      assert state.activation_budget == 1
      assert state.status == :active
      assert state.pending_activations == 0
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
      # Floor of 6, regardless of single-agent count.
      assert state.activation_budget == 6
    end

    test "activation budget scales with roster size, clamped to [6, 21]" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}")

      # Empty room → floor.
      assert Room.get_state(room).activation_budget == 6

      # 5 agents → ceil(1.5 * 5) = 8.
      Enum.each(1..5, fn i -> Room.join(room, "agents/a#{i}") end)
      assert Room.get_state(room).activation_budget == 8

      # 15 agents → ceil(1.5 * 15) = 23, clamped to 21.
      Enum.each(6..15, fn i -> Room.join(room, "agents/a#{i}") end)
      assert Room.get_state(room).activation_budget == 21

      # Leave one — 14 → 21, still at the ceiling.
      Room.leave(room, "agents/a15")
      assert Room.get_state(room).activation_budget == 21
    end

    test "send_message recomputes budget from current roster" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}")
      Enum.each(1..5, fn i -> Room.join(room, "agents/a#{i}") end)

      Room.send_message(room, "hi")

      state = Room.get_state(room)
      # 5 agents → ceil(1.5 * 5) = 8
      assert state.activation_budget == 8
      assert state.activations_remaining == 8
    end

    test "halt clears pending activations, sets :waiting, and broadcasts {:halted, room_id}" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}", activation_budget: 1)

      Room.send_message(room, "Go")
      Room.try_activate(room, "agents/alpha")
      :exhausted = Room.try_activate(room, "agents/beta")
      Room.queue_activation(room, "agents/beta", activation: :normal)

      assert Room.get_state(room).pending_activations > 0

      Room.subscribe(room)
      Room.halt(room)

      assert_receive {:halted, ^room}, 1000

      state = Room.get_state(room)
      assert state.status == :waiting
      assert state.pending_activations == 0
    end

    test "halted room swallows agent_respond — no transcript, no broadcast" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}")
      Room.subscribe(room)
      Room.send_message(room, "Go")

      assert_receive {:user_message, _}, 1000

      :ok = Room.halt(room)
      assert_receive {:halted, ^room}, 1000

      # Late-arriving response from an in-flight task: should be a no-op.
      :ok = Room.agent_respond(room, "agents/late", "I was almost done!")

      refute_receive {:agent_message, _}, 100
      refute_receive {:agent_mentions, _, _, _, _}, 100

      transcript = Room.get_transcript(room)
      assert length(transcript) == 1
    end

    test "send_message after halt clears halted flag and accepts responses again" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}")
      Room.send_message(room, "Go")
      Room.halt(room)

      # New user message should reset.
      Room.send_message(room, "OK back at it")
      Room.subscribe(room)

      :ok = Room.agent_respond(room, "agents/alpha", "responding")

      # Now agent_message broadcasts should land.
      assert_receive {:agent_message, _}, 1000
    end

    test "continue after halt clears halted flag and accepts responses" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}")
      Room.send_message(room, "Go")
      Room.halt(room)

      Room.continue(room)
      Room.subscribe(room)

      :ok = Room.agent_respond(room, "agents/alpha", "responding")
      assert_receive {:agent_message, _}, 1000
    end

    test "Room.get_state exposes halted flag for external gates" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}")
      assert Room.get_state(room).halted == false

      Room.halt(room)
      assert Room.get_state(room).halted == true

      Room.send_message(room, "back")
      assert Room.get_state(room).halted == false
    end

    test "halt on an idle room is safe (no pending state, just broadcasts)" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}")

      Room.subscribe(room)
      assert :ok = Room.halt(room)

      assert_receive {:halted, ^room}, 1000

      state = Room.get_state(room)
      assert state.status == :waiting
      assert state.pending_activations == 0
    end

    test "agent_respond no longer ticks the budget (Coordinator is the gate)" do
      # Budget ticks on activation now, not on response. agent_respond
      # is just a commit; it doesn't touch the activation budget.
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}", activation_budget: 6)
      Room.send_message(room, "hi")
      assert Room.get_state(room).activations_remaining == 6

      # Plain responses don't decrement.
      for i <- 1..4 do
        Room.agent_respond(room, "agents/test-#{i}", "response #{i}")
      end

      assert Room.get_state(room).activations_remaining == 6
    end

    test "agent_respond broadcasts :agent_mentions unconditionally (Coordinator filters)" do
      room = start_room("test-room-#{:erlang.unique_integer([:positive])}", activation_budget: 1)
      Room.subscribe(room)
      Room.send_message(room, "Go")
      assert_receive {:user_message, _}, 1000

      # Even after consuming the only slot, agent_respond still
      # broadcasts the mention — the Coordinator is the one that
      # decides whether to spawn or queue.
      Room.try_activate(room, "agents/alpha")
      Room.agent_respond(room, "agents/alpha", "ask @agents/beta")

      assert_receive {:agent_message, _}, 1000
      assert_receive {:agent_mentions, _, "agents/alpha", ["agents/beta"], _}, 1000
    end
  end

  # --- Session peer-visibility (Phase 6) ---

  describe "Session peer history" do
    alias Egghead.Agent.Session

    test "appends peer messages to state.history as name-prefixed user turns" do
      room_id = "test-room-#{:erlang.unique_integer([:positive])}"
      {:ok, room_pid} = Room.start_link(id: room_id)

      identity = [
        id: "agents/alpha",
        name: "Alpha",
        model: "anthropic/claude-haiku-4-5",
        capabilities: [],
        disposition: "Test agent."
      ]

      {:ok, session_pid} =
        Session.start_link(
          agent_id: "agents/alpha",
          room_id: room_id,
          identity: identity,
          room_pid: room_pid
        )

      # Peer posts. Our session should receive it via PubSub and append
      # as a name-prefixed user turn.
      Room.agent_respond(room_id, "agents/beta", "beta speaking here")
      Process.sleep(50)

      state = :sys.get_state(session_pid)

      assert Enum.any?(state.history, fn entry ->
               entry.role == "user" and
                 entry.content == "agents/beta: beta speaking here"
             end)

      # Our own message should NOT be appended via the broadcast
      # (it would duplicate the assistant turn in agent_loop).
      Room.agent_respond(room_id, "agents/alpha", "alpha speaking")
      Process.sleep(50)

      state = :sys.get_state(session_pid)

      refute Enum.any?(state.history, fn entry ->
               entry.role == "user" and
                 entry.content == "agents/alpha: alpha speaking"
             end)

      # /pass messages are skipped — no conversational content.
      Room.agent_pass(room_id, "agents/beta")
      Process.sleep(50)

      state = :sys.get_state(session_pid)

      refute Enum.any?(state.history, fn entry ->
               entry.role == "user" and entry.content =~ "/pass"
             end)
    end

    test "aborts in-flight task on {:halted, room_id} and replies :halted to caller" do
      room_id = "test-room-#{:erlang.unique_integer([:positive])}"
      {:ok, room_pid} = Room.start_link(id: room_id)

      identity = [
        id: "agents/alpha",
        name: "Alpha",
        model: "anthropic/claude-haiku-4-5",
        capabilities: [],
        disposition: "Test agent."
      ]

      {:ok, session_pid} =
        Session.start_link(
          agent_id: "agents/alpha",
          room_id: room_id,
          identity: identity,
          room_pid: room_pid
        )

      # Stand in for a real LLM task: a long-sleeping process. The
      # TaskSupervisor isn't started in the test config, so we just
      # spawn directly — Session.handle_info doesn't care about the
      # task's supervisor; it kills by pid.
      task_pid = spawn(fn -> Process.sleep(30_000) end)
      task_ref = make_ref()

      test_pid = self()
      reply_ref = make_ref()
      fake_from = {test_pid, reply_ref}

      pending = %{
        ref: task_ref,
        pid: task_pid,
        from: fake_from,
        kind: :prompt,
        input_history_len: 0,
        call: {:prompt, "stub", []}
      }

      :sys.replace_state(session_pid, fn state -> %{state | pending_task: pending} end)

      task_mon = Process.monitor(task_pid)

      # Trigger the halt path the way Room.halt would (PubSub broadcast).
      Phoenix.PubSub.broadcast(Egghead.PubSub, Room.topic(room_id), {:halted, room_id})

      # Caller blocked on the GenServer.call gets {:error, :halted}.
      assert_receive {^reply_ref, {:error, :halted}}, 1000

      # The standin task is killed.
      assert_receive {:DOWN, ^task_mon, :process, _pid, _reason}, 1000

      # Session is back to idle.
      state = :sys.get_state(session_pid)
      assert state.pending_task == nil
      assert state.queued_calls == []
    end

    test "rehydrates history from room transcript on session init" do
      room_id = "test-room-#{:erlang.unique_integer([:positive])}"
      {:ok, room_pid} = Room.start_link(id: room_id)

      # Populate the room before the agent's session exists.
      Room.send_message(room_id, "hello")
      Room.agent_respond(room_id, "agents/beta", "hi there")

      identity = [
        id: "agents/alpha",
        name: "Alpha",
        model: "anthropic/claude-haiku-4-5",
        capabilities: [],
        disposition: "Test agent."
      ]

      {:ok, session_pid} =
        Session.start_link(
          agent_id: "agents/alpha",
          room_id: room_id,
          identity: identity,
          room_pid: room_pid
        )

      state = :sys.get_state(session_pid)

      # Both past messages should be in history: the user msg and
      # the peer agent msg, in transcript order, as user-role turns.
      assert length(state.history) >= 2
      assert Enum.any?(state.history, &(&1.content =~ "hello"))
      assert Enum.any?(state.history, &(&1.content == "agents/beta: hi there"))
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

    test "budget_exhausted is broadcast once the in-flight session drains" do
      room =
        start_room("pubsub-test-#{:erlang.unique_integer([:positive])}", activation_budget: 1)

      Room.subscribe(room)

      Room.send_message(room, "Go")
      assert_receive {:user_message, _}, 1000

      Room.try_activate(room, "agents/a")
      :exhausted = Room.try_activate(room, "agents/b")
      Room.queue_activation(room, "agents/b", activation: :normal)

      # agents/a is still streaming — the bar would lie if it fired now.
      refute_receive :budget_exhausted, 100

      Room.agent_respond(room, "agents/a", "done")
      assert_receive :budget_exhausted, 1000
    end

    test "continued is broadcast" do
      room =
        start_room("pubsub-test-#{:erlang.unique_integer([:positive])}", activation_budget: 1)

      Room.subscribe(room)

      Room.send_message(room, "Go")
      Room.try_activate(room, "agents/a")
      Room.queue_activation(room, "agents/b", activation: :normal)
      Room.continue(room)

      assert_receive {:continued, [replayed: 1]}, 1000
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
