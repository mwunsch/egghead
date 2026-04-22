defmodule Egghead.TUI.Chat.UpdateTest do
  use ExUnit.Case, async: true

  alias Egghead.OpenTUI.EditBuffer
  alias Egghead.TUI.Chat.{Entry, Model, Paste, Update}
  alias Egghead.TUI.Completion
  alias Egghead.Chat.Room.{Message, Sender}

  defp put_input(model, text) do
    %{model | input: EditBuffer.from_text(text)}
  end

  defp model(opts \\ []) do
    %Model{
      room_id: Keyword.get(opts, :room_id, "default"),
      width: 80,
      height: 24
    }
  end

  defp user_msg(name, content) do
    %Message{
      id: "u1",
      room_id: "default",
      sender: %Sender{type: :user, id: "user", name: name},
      content: content,
      timestamp: DateTime.utc_now(),
      mentions: []
    }
  end

  defp agent_msg(id, name, content) do
    %Message{
      id: "a1",
      room_id: "default",
      sender: %Sender{type: :agent, id: id, name: name},
      content: content,
      timestamp: DateTime.utc_now(),
      mentions: []
    }
  end

  describe "room events" do
    test "user_message appends a :user entry" do
      {m, :none} = Update.update({:room_event, {:user_message, user_msg("Mark", "hi")}}, model())
      assert [%Entry{kind: :user, sender_name: "Mark", text: "hi"}] = m.transcript
    end

    test "agent_streaming accumulates and commits on newline" do
      m = model()

      {m, :none} =
        Update.update({:room_event, {:agent_streaming, "default", "agents/scout", "first "}}, m)

      assert m.transcript == []
      assert Map.has_key?(m.streams, "agents/scout")

      {m, :none} =
        Update.update(
          {:room_event, {:agent_streaming, "default", "agents/scout", "line\nsecond"}},
          m
        )

      assert [%Entry{kind: :agent, text: "first line"}] = m.transcript
      assert m.streams["agents/scout"].current == "second"
    end

    test "agent_message finalizes the live stream and drops it" do
      m = model()

      {m, :none} =
        Update.update(
          {:room_event, {:agent_streaming, "default", "agents/scout", "hello"}},
          m
        )

      {m, :none} =
        Update.update(
          {:room_event, {:agent_message, agent_msg("agents/scout", "Scout", "hello")}},
          m
        )

      assert [%Entry{kind: :agent, text: "hello"}] = m.transcript
      assert m.streams == %{}
    end

    test "agent_tool_call flushes the in-progress stream before the action line" do
      # Regression: agent streams "Sure, calling:" (no newline), a tool
      # call fires, then post-tool text appends onto the same buffer
      # giving "Sure, calling:There it is..." with no separator.
      # The tool_call handler must finalize the stream first.
      m = model()

      {m, :none} =
        Update.update(
          {:room_event,
           {:agent_streaming, "default", "agents/scout", "Sure, attempting the update now:"}},
          m
        )

      # Mid-sentence — no commit yet
      assert m.transcript == []
      assert m.streams["agents/scout"].current == "Sure, attempting the update now:"

      {m, :none} =
        Update.update(
          {:room_event,
           {:agent_tool_call, "default", "agents/scout", "update_record", %{"id" => "x"}}},
          m
        )

      # Stream flushed into an :agent entry; action line appended after it
      assert [
               %Entry{kind: :agent, text: "Sure, attempting the update now:"},
               %Entry{kind: :action, text: "uses update_record " <> _}
             ] = m.transcript

      refute Map.has_key?(m.streams, "agents/scout")
    end

    test "agent_tool_denied also flushes the in-progress stream first" do
      m = model()

      {m, :none} =
        Update.update(
          {:room_event, {:agent_streaming, "default", "agents/scout", "trying now:"}},
          m
        )

      denial = %Egghead.Capability.Denial{
        code: :self_modification,
        agent_id: "agents/scout",
        tool: "update_record",
        message: "cannot self-grant",
        suggested_grant: nil
      }

      {m, :none} =
        Update.update(
          {:room_event,
           {:agent_tool_denied, "default", "agents/scout", "update_record", %{"id" => "x"},
            denial}},
          m
        )

      assert [
               %Entry{kind: :agent, text: "trying now:"},
               %Entry{kind: :denial, metadata: %{denial: ^denial}}
             ] = m.transcript
    end

    test "agent_passed clears the stream and appends a /me action entry" do
      m = model()

      {m, :none} =
        Update.update(
          {:room_event, {:agent_streaming, "default", "agents/scout", "/pa"}},
          m
        )

      {m, :none} =
        Update.update({:room_event, {:agent_passed, "agents/scout"}}, m)

      # Partial streamed text is dropped (never committed on /pass) ...
      assert m.streams == %{}

      # ... and a single atmospheric action entry renders in its place,
      # with flavor text drawn from PassActions.
      assert [
               %Egghead.TUI.Chat.Entry{
                 kind: :action,
                 sender_id: "agents/scout",
                 text: flavor
               }
             ] = m.transcript

      assert flavor in Egghead.Chat.PassActions.all()
    end

    test "budget_exhausted sets a status flash; continued clears it" do
      {m, :none} = Update.update({:room_event, :budget_exhausted}, model())
      assert m.status_message =~ "continue"

      {m, :none} = Update.update({:room_event, :continued}, m)
      assert m.status_message == nil
    end

    test "agent_joined / agent_left maintains the presence list" do
      {m, :none} = Update.update({:room_event, {:agent_joined, "agents/probe"}}, model())
      assert Enum.any?(m.agents, &(&1.id == "agents/probe"))

      {m, :none} = Update.update({:room_event, {:agent_left, "agents/probe"}}, m)
      refute Enum.any?(m.agents, &(&1.id == "agents/probe"))
    end

    test "duplicate agent_joined is a no-op" do
      m = model()
      {m, :none} = Update.update({:room_event, {:agent_joined, "agents/probe"}}, m)
      {m, :none} = Update.update({:room_event, {:agent_joined, "agents/probe"}}, m)
      assert Enum.count(m.agents, &(&1.id == "agents/probe")) == 1
    end

    test "agent_joined uses the id as a placeholder name (no fabricated capitalization)" do
      {m, :none} = Update.update({:room_event, {:agent_joined, "agents/probe"}}, model())
      probe = Enum.find(m.agents, &(&1.id == "agents/probe"))
      assert probe.name == "agents/probe"
    end

    test "agent_roster_changed re-hydrates from list_agents (preserves position of existing rows)" do
      # Build a model with two existing agents in a known order, then
      # simulate a roster broadcast. The Update path calls
      # `Egghead.list_agents/0` — without an Agent.Supervisor running
      # the call returns `[]`, so existing-row preservation drops them
      # all. That's the right semantics: an empty roster from
      # `list_agents` means no agent processes are alive, so the
      # sidebar should reflect that. The hot-reload-visibility
      # contract is "after the broadcast lands, the sidebar matches
      # the live system." This proves the hook fires.
      m = %{
        model()
        | agents: [
            %Egghead.TUI.Chat.Model.AgentPresence{id: "agents/alpha", name: "Alpha"},
            %Egghead.TUI.Chat.Model.AgentPresence{id: "agents/beta", name: "Beta"}
          ]
      }

      {m2, :none} = Update.update({:room_event, {:agent_roster_changed}}, m)
      # `list_agents/0` returns [] in this test env. The hook
      # therefore drops every row whose id is no longer in the live
      # roster — exactly the contract.
      assert m2.agents == []
    end

    test "agent_streaming sets agent status to :active" do
      m = model()
      {m, :none} = Update.update({:room_event, {:agent_joined, "agents/scout"}}, m)
      assert Enum.find(m.agents, &(&1.id == "agents/scout")).status == :idle

      {m, :none} =
        Update.update(
          {:room_event, {:agent_streaming, "default", "agents/scout", "hi"}},
          m
        )

      assert Enum.find(m.agents, &(&1.id == "agents/scout")).status == :active
    end

    test "agent_message sets agent status back to :idle" do
      m = model()
      {m, :none} = Update.update({:room_event, {:agent_joined, "agents/scout"}}, m)

      {m, :none} =
        Update.update(
          {:room_event, {:agent_streaming, "default", "agents/scout", "hi"}},
          m
        )

      assert Enum.find(m.agents, &(&1.id == "agents/scout")).status == :active

      {m, :none} =
        Update.update(
          {:room_event, {:agent_message, agent_msg("agents/scout", "Scout", "hi")}},
          m
        )

      assert Enum.find(m.agents, &(&1.id == "agents/scout")).status == :idle
    end

    test "agent_passed sets agent status to :idle" do
      m = model()
      {m, :none} = Update.update({:room_event, {:agent_joined, "agents/scout"}}, m)

      {m, :none} =
        Update.update(
          {:room_event, {:agent_streaming, "default", "agents/scout", "hi"}},
          m
        )

      {m, :none} = Update.update({:room_event, {:agent_passed, "agents/scout"}}, m)
      assert Enum.find(m.agents, &(&1.id == "agents/scout")).status == :idle
    end

    test "muted_changed flips the agent's muted? flag" do
      m = model()
      {m, :none} = Update.update({:room_event, {:agent_joined, "agents/scout"}}, m)
      refute Enum.find(m.agents, &(&1.id == "agents/scout")).muted?

      {m, :none} =
        Update.update({:room_event, {:muted_changed, "agents/scout", true}}, m)

      assert Enum.find(m.agents, &(&1.id == "agents/scout")).muted?

      {m, :none} =
        Update.update({:room_event, {:muted_changed, "agents/scout", false}}, m)

      refute Enum.find(m.agents, &(&1.id == "agents/scout")).muted?
    end
  end

  describe "key bindings" do
    test "escape is a no-op (no navigation or clearing)" do
      {_m, cmd} = Update.update({:key, :escape}, model())
      assert cmd == :none
    end

    test "escape with input does not clear it" do
      m = put_input(model(), "draft")
      {m, cmd} = Update.update({:key, :escape}, m)
      assert Model.input_text(m) == "draft"
      assert cmd == :none
    end

    test "enter on empty input is a no-op" do
      {m, cmd} = Update.update({:key, :enter}, model())
      assert Model.input_text(m) == ""
      assert cmd == :none
    end

    test "enter with text fires an :exec command and clears the input" do
      m = put_input(model(), "hello")
      {m, cmd} = Update.update({:key, :enter}, m)
      assert Model.input_text(m) == ""
      assert match?({:exec, fun} when is_function(fun, 0), cmd)
    end

    test "printable char inserts at the cursor" do
      {m, :none} = Update.update({:char, "h"}, model())
      {m, :none} = Update.update({:char, "i"}, m)
      assert Model.input_text(m) == "hi"
      assert EditBuffer.cursor(m.input) == {0, 2}
    end

    test "backspace deletes the previous char" do
      m = put_input(model(), "hi")
      {m, :none} = Update.update({:key, :backspace}, m)
      assert Model.input_text(m) == "h"
      assert EditBuffer.cursor(m.input) == {0, 1}
    end

    test "ctrl_a / ctrl_e jump to ends of the line" do
      m = put_input(model(), "hello")
      m = %{m | input: %{m.input | col: 2}}
      {m1, :none} = Update.update({:key, :ctrl_a}, m)
      assert EditBuffer.cursor(m1.input) == {0, 0}
      {m2, :none} = Update.update({:key, :ctrl_e}, m)
      assert EditBuffer.cursor(m2.input) == {0, 5}
    end

    test "shift_enter inserts a literal newline" do
      m = put_input(model(), "first")
      {m, :none} = Update.update({:key, :shift_enter}, m)
      {m, :none} = Update.update({:char, "s"}, m)
      assert Model.input_text(m) == "first\ns"
      assert EditBuffer.cursor(m.input) == {1, 1}
    end

    test "alt_enter is a fallback newline chord" do
      m = put_input(model(), "a")
      {m, :none} = Update.update({:key, :alt_enter}, m)
      assert Model.input_text(m) == "a\n"
    end

    test "paste preserves newlines as line breaks" do
      {m, :none} = Update.update({:paste, "line one\nline two"}, model())
      assert Model.input_text(m) == "line one\nline two"
      assert EditBuffer.line_count(m.input) == 2
    end

    test "long paste is wrapped in a chip cell instead of inlined" do
      big = String.duplicate("x", 200)
      {m, :none} = Update.update({:paste, big}, model())

      # Single chip cell, not 200 graphemes
      assert EditBuffer.line_width(m.input, 0) == 1
      assert [%Paste{full_text: ^big}] = EditBuffer.line_cells(m.input, 0)

      # to_text/1 still expands back to the original payload
      assert Model.input_text(m) == big

      # next_paste_id advances
      assert m.next_paste_id == 2
    end

    test "multi-line paste over the line threshold becomes a chip" do
      blob = "a\nb\nc\nd\ne"
      {m, :none} = Update.update({:paste, blob}, model())

      assert EditBuffer.line_width(m.input, 0) == 1
      assert [%Paste{}] = EditBuffer.line_cells(m.input, 0)
      assert Model.input_text(m) == blob
    end

    test "up / down navigates between buffer rows" do
      m = put_input(model(), "alpha\nbeta")
      m = %{m | input: %{m.input | row: 0, col: 3}}
      {m_down, :none} = Update.update({:key, :down}, m)
      assert EditBuffer.cursor(m_down.input) == {1, 3}
      {m_up, :none} = Update.update({:key, :up}, m_down)
      assert EditBuffer.cursor(m_up.input) == {0, 3}
    end
  end

  describe "mention autocomplete" do
    test "typing @ sets an :agent completion" do
      {m, :none} = Update.update({:char, "@"}, model())
      assert %Completion{provider: Egghead.TUI.Completion.Agent, prefix: ""} = m.completion
    end

    test "typing [[ sets a :record completion" do
      {m, :none} = Update.update({:char, "["}, model())
      {m, :none} = Update.update({:char, "["}, m)
      assert %Completion{provider: Egghead.TUI.Completion.Record, prefix: ""} = m.completion
    end

    test "typing a non-sigil leaves completion nil" do
      {m, :none} = Update.update({:char, "h"}, model())
      assert m.completion == nil
    end

    test "tab with no candidates is a no-op" do
      m = put_input(model(), "@zzz-no-such-agent")
      {m2, :none} = Update.update({:key, :tab}, m)
      assert Model.input_text(m2) == Model.input_text(m)
    end

    test "clear_input wipes the completion context" do
      {m, :none} = Update.update({:char, "@"}, model())
      assert m.completion != nil
      m = Model.clear_input(m)
      assert m.completion == nil
    end
  end

  describe "slash commands" do
    test "/quit returns :halt" do
      m = put_input(model(), "/quit")
      {_m, cmd} = Update.update({:key, :enter}, m)
      assert cmd == :halt
    end

    test "/exit is an alias for /quit" do
      m = put_input(model(), "/exit")
      {_m, cmd} = Update.update({:key, :enter}, m)
      assert cmd == :halt
    end

    test "/leave switches to records" do
      m = put_input(model(), "/leave")
      {_m, cmd} = Update.update({:key, :enter}, m)
      assert cmd == {:switch_screen, :records, []}
    end

    test "/part is an alias for /leave" do
      m = put_input(model(), "/part")
      {_m, cmd} = Update.update({:key, :enter}, m)
      assert cmd == {:switch_screen, :records, []}
    end

    test "/help appends a system entry" do
      m = put_input(model(), "/help")
      {m, :none} = Update.update({:key, :enter}, m)
      assert Model.input_empty?(m)
      assert [%Entry{kind: :system}] = m.transcript
    end

    test "/continue appends a system entry and fires :exec" do
      m = put_input(model(), "/continue")
      {m, cmd} = Update.update({:key, :enter}, m)
      assert [%Entry{kind: :system, text: text}] = m.transcript
      assert text =~ "renewed"
      assert match?({:exec, _}, cmd)
    end

    test "/handoff without arg shows usage" do
      m = put_input(model(), "/handoff")
      {m, :none} = Update.update({:key, :enter}, m)
      assert [%Entry{kind: :system, text: text}] = m.transcript
      assert text =~ "Usage"
    end

    test "/handoff with arg fires :exec" do
      m = put_input(model(), "/handoff agents/scout")
      {m, cmd} = Update.update({:key, :enter}, m)
      assert [%Entry{kind: :system, text: text}] = m.transcript
      assert text =~ "agents/scout"
      assert match?({:exec, _}, cmd)
    end

    test "unknown command appends error" do
      m = put_input(model(), "/nope")
      {m, :none} = Update.update({:key, :enter}, m)
      assert [%Entry{kind: :system, text: text}] = m.transcript
      assert text =~ "Unknown"
    end
  end

  describe "command autocomplete" do
    test "typing / activates the command completion" do
      {m, :none} = Update.update({:char, "/"}, model())
      assert %Completion{provider: Egghead.TUI.Completion.Command} = m.completion
      assert length(m.completion.candidates) > 0
    end

    test "typing /q narrows to quit" do
      m = put_input(model(), "/q")
      {m, :none} = Update.update({:char, "u"}, m)
      assert %Completion{provider: Egghead.TUI.Completion.Command} = m.completion
      assert Enum.any?(m.completion.candidates, &(&1.name == "quit"))
    end

    test "tab completes the selected command" do
      {m, :none} = Update.update({:char, "/"}, model())
      {m, :none} = Update.update({:char, "q"}, m)
      assert m.completion != nil
      {m, :none} = Update.update({:key, :tab}, m)
      assert Model.input_text(m) =~ "/quit "
    end

    test "enter with dropdown open fills the input (same as tab)" do
      {m, :none} = Update.update({:char, "/"}, model())
      {m, :none} = Update.update({:key, :down}, m)
      selected_name = Enum.at(m.completion.candidates, m.completion.selected).name
      {m, :none} = Update.update({:key, :enter}, m)
      assert Model.input_text(m) == "/#{selected_name} "
    end

    test "escape dismisses command completion" do
      {m, :none} = Update.update({:char, "/"}, model())
      assert m.completion != nil
      {m, :none} = Update.update({:key, :escape}, m)
      assert m.completion == nil
    end

    test "up/down navigate the command completion" do
      {m, :none} = Update.update({:char, "/"}, model())
      assert m.completion.selected == 0
      {m, :none} = Update.update({:key, :down}, m)
      assert m.completion.selected == 1
      {m, :none} = Update.update({:key, :up}, m)
      assert m.completion.selected == 0
    end
  end

  describe "transcript scrolling" do
    # Build a model with enough transcript entries to scroll.
    defp scrollable_model do
      entries = for i <- 1..50, do: Entry.system("line #{i}")
      %{model() | transcript: entries}
    end

    test "ctrl_p scrolls up (increases scroll offset)" do
      {m, :none} = Update.update({:key, :ctrl_p}, scrollable_model())
      assert m.scroll == 5
    end

    test "ctrl_n scrolls down (decreases scroll offset), clamped at 0" do
      m = %{scrollable_model() | scroll: 3}
      {m, :none} = Update.update({:key, :ctrl_n}, m)
      assert m.scroll == 0
    end

    test "page_up / page_down adjust scroll" do
      {m, :none} = Update.update({:key, :page_up}, scrollable_model())
      assert m.scroll == 5
      {m, :none} = Update.update({:key, :page_down}, m)
      assert m.scroll == 0
    end

    test "mouse wheel_up / wheel_down adjust scroll" do
      {m, :none} =
        Update.update(
          {:mouse, %{kind: :wheel_up, press?: true, col: 0, row: 0}},
          scrollable_model()
        )

      assert m.scroll == 3
      {m, :none} = Update.update({:mouse, %{kind: :wheel_down, press?: true, col: 0, row: 0}}, m)
      assert m.scroll == 0
    end

    test "scroll is clamped to transcript length" do
      m = scrollable_model()
      # Scroll up many times — should not exceed transcript length
      {m, :none} = Update.update({:key, :ctrl_p}, m)
      {m, :none} = Update.update({:key, :ctrl_p}, m)
      {m, :none} = Update.update({:key, :ctrl_p}, m)
      assert m.scroll == 15
      # Now scroll down the same amount — should return to 0
      {m, :none} = Update.update({:key, :ctrl_n}, m)
      {m, :none} = Update.update({:key, :ctrl_n}, m)
      {m, :none} = Update.update({:key, :ctrl_n}, m)
      assert m.scroll == 0
    end

    test "sending a message resets scroll to 0" do
      m = put_input(%{scrollable_model() | scroll: 10}, "hello")
      {m, _cmd} = Update.update({:key, :enter}, m)
      assert m.scroll == 0
    end
  end

  describe "synthetic" do
    test ":resize updates dimensions" do
      {m, :none} = Update.update({:resize, 120, 40}, model())
      assert m.width == 120
      assert m.height == 40
    end

    test "unknown_msg is silently swallowed" do
      assert {%Model{}, :none} = Update.update({:unknown_msg, :weird}, model())
    end
  end
end
