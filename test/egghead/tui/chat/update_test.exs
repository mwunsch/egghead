defmodule Egghead.TUI.Chat.UpdateTest do
  use ExUnit.Case, async: true

  alias Egghead.TUI.Chat.{Entry, Model, Update}
  alias Egghead.Chat.Room.{Message, Sender}

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
      m = %{model() | input: "draft", cursor: 5}
      {m, cmd} = Update.update({:key, :escape}, m)
      assert m.input == ""
      assert cmd == :none
    end

    test "enter on empty input is a no-op" do
      {m, cmd} = Update.update({:key, :enter}, model())
      assert m.input == ""
      assert cmd == :none
    end

    test "enter with text fires an :exec command and clears the input" do
      m = %{model() | input: "hello", cursor: 5}
      {m, cmd} = Update.update({:key, :enter}, m)
      assert m.input == ""
      assert m.cursor == 0
      assert match?({:exec, fun} when is_function(fun, 0), cmd)
    end

    test "printable char inserts at the cursor" do
      {m, :none} = Update.update({:char, "h"}, model())
      {m, :none} = Update.update({:char, "i"}, m)
      assert m.input == "hi"
      assert m.cursor == 2
    end

    test "backspace deletes the previous char" do
      m = %{model() | input: "hi", cursor: 2}
      {m, :none} = Update.update({:key, :backspace}, m)
      assert m.input == "h"
      assert m.cursor == 1
    end

    test "ctrl_a / ctrl_e jump to ends of the line" do
      m = %{model() | input: "hello", cursor: 2}
      {m1, :none} = Update.update({:key, :ctrl_a}, m)
      assert m1.cursor == 0
      {m2, :none} = Update.update({:key, :ctrl_e}, m)
      assert m2.cursor == 5
    end

    test "paste flattens newlines for the single-line input (Phase 6c)" do
      {m, :none} = Update.update({:paste, "line one\nline two"}, model())
      assert m.input == "line one line two"
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
