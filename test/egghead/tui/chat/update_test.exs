defmodule Egghead.TUI.Chat.UpdateTest do
  use ExUnit.Case, async: true

  alias Egghead.OpenTUI.EditBuffer
  alias Egghead.TUI.Chat.{Entry, Mentions, Model, Paste, Update}
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

    test "agent_streaming accumulates and commits paragraphs" do
      m = model()

      {m, :none} =
        Update.update({:room_event, {:agent_streaming, "default", "agents/scout", "first "}}, m)

      assert m.transcript == []
      assert Map.has_key?(m.streams, "agents/scout")

      {m, :none} =
        Update.update(
          {:room_event, {:agent_streaming, "default", "agents/scout", "para\n\nsecond"}},
          m
        )

      assert [%Entry{kind: :agent, text: "first para"}] = m.transcript
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

    test "agent_passed clears the stream without committing partial text" do
      m = model()

      {m, :none} =
        Update.update(
          {:room_event, {:agent_streaming, "default", "agents/scout", "[PA"}},
          m
        )

      {m, :none} =
        Update.update({:room_event, {:agent_passed, "agents/scout"}}, m)

      assert m.streams == %{}
      assert m.transcript == []
    end

    test "budget_exhausted sets a status flash; continued clears it" do
      {m, :none} = Update.update({:room_event, :budget_exhausted}, model())
      assert m.status_message =~ "budget"

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
  end

  describe "key bindings" do
    test "escape on empty input returns to records mode" do
      {_m, cmd} = Update.update({:key, :escape}, model())
      assert cmd == {:switch_screen, :records, []}
    end

    test "escape with input clears the input instead of leaving" do
      m = put_input(model(), "draft")
      {m, cmd} = Update.update({:key, :escape}, m)
      assert Model.input_text(m) == ""
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
    test "typing @ sets an :agent mention context" do
      {m, :none} = Update.update({:char, "@"}, model())
      assert %Mentions.Context{kind: :agent, prefix: ""} = m.mention
    end

    test "typing [[ sets a :record mention context" do
      {m, :none} = Update.update({:char, "["}, model())
      {m, :none} = Update.update({:char, "["}, m)
      assert %Mentions.Context{kind: :record, prefix: ""} = m.mention
    end

    test "typing a non-sigil leaves mention nil" do
      {m, :none} = Update.update({:char, "h"}, model())
      assert m.mention == nil
    end

    test "tab with no candidates is a no-op" do
      m = put_input(model(), "@zzz-no-such-agent")
      {m2, :none} = Update.update({:key, :tab}, m)
      assert Model.input_text(m2) == Model.input_text(m)
    end

    test "clear_input wipes the mention context" do
      {m, :none} = Update.update({:char, "@"}, model())
      assert m.mention != nil
      m = Model.clear_input(m)
      assert m.mention == nil
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
