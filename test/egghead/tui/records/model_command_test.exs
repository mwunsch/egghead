defmodule Egghead.TUI.Records.ModelCommandTest do
  use ExUnit.Case, async: true

  alias Egghead.TUI.Records.Model

  describe "enter_command_mode/1" do
    test "sets command_mode true and resets input + selection" do
      m = %Model{command_mode: false, command_input: "stale", command_selected: 3}
      m = Model.enter_command_mode(m)
      assert m.command_mode == true
      assert m.command_input == ""
      assert m.command_selected == 0
    end

    test "is idempotent" do
      m = %Model{} |> Model.enter_command_mode() |> Model.enter_command_mode()
      assert m.command_mode == true
      assert m.command_input == ""
    end
  end

  describe "exit_command_mode/1" do
    test "clears command state" do
      m = %Model{command_mode: true, command_input: "abc", command_selected: 2}
      m = Model.exit_command_mode(m)
      assert m.command_mode == false
      assert m.command_input == ""
      assert m.command_selected == 0
    end
  end

  describe "command_input_char/2" do
    test "inserts at the cursor and resets dropdown selection to 0" do
      m =
        %Model{
          command_mode: true,
          command_input: "h",
          command_cursor: 1,
          command_selected: 4
        }
        |> Model.command_input_char("e")

      assert m.command_input == "he"
      assert m.command_cursor == 2
      assert m.command_selected == 0
    end

    test "inserts in the middle when cursor is mid-input" do
      m =
        %Model{command_mode: true, command_input: "hp", command_cursor: 1}
        |> Model.command_input_char("e")
        |> Model.command_input_char("l")

      assert m.command_input == "help"
      assert m.command_cursor == 3
    end
  end

  describe "command_backspace/1" do
    test "deletes the char before the cursor" do
      m =
        %Model{command_mode: true, command_input: "help", command_cursor: 4}
        |> Model.command_backspace()

      assert m.command_input == "hel"
      assert m.command_cursor == 3
      assert m.command_mode == true
    end

    test "exits command mode on empty input" do
      m =
        %Model{command_mode: true, command_input: ""}
        |> Model.command_backspace()

      assert m.command_mode == false
    end
  end

  describe "filtered_commands/1" do
    test "returns all commands when input is empty" do
      m = %Model{command_mode: true, command_input: ""}
      cmds = Model.filtered_commands(m)
      assert length(cmds) == length(Model.all_commands())
    end

    test "filters by case-insensitive prefix" do
      m = %Model{command_mode: true, command_input: "h"}
      cmds = Model.filtered_commands(m)
      assert Enum.any?(cmds, &(&1.name == "help"))
      refute Enum.any?(cmds, &(&1.name == "quit"))
    end

    test "case-insensitive" do
      m = %Model{command_mode: true, command_input: "QUI"}
      cmds = Model.filtered_commands(m)
      assert Enum.any?(cmds, &(&1.name == "quit"))
    end

    test "empty list for no match" do
      m = %Model{command_mode: true, command_input: "xyzzy"}
      assert Model.filtered_commands(m) == []
    end
  end

  describe "command_select/2" do
    test "moves selection within bounds" do
      m =
        %Model{command_mode: true, command_input: "", command_selected: 0}
        |> Model.command_select(+2)

      assert m.command_selected == 2
    end

    test "clamps to last index" do
      n = length(Model.all_commands())

      m =
        %Model{command_mode: true, command_input: "", command_selected: 0}
        |> Model.command_select(+99)

      assert m.command_selected == n - 1
    end

    test "clamps to 0" do
      m =
        %Model{command_mode: true, command_input: "", command_selected: 0}
        |> Model.command_select(-5)

      assert m.command_selected == 0
    end

    test "clamps to 0 when filtered list is empty" do
      m =
        %Model{command_mode: true, command_input: "xyzzy", command_selected: 0}
        |> Model.command_select(+1)

      assert m.command_selected == 0
    end
  end

  describe "selected_command/1" do
    test "returns the entry at command_selected" do
      m = %Model{command_mode: true, command_input: "h", command_selected: 0}
      assert Model.selected_command(m).name == "help"
    end

    test "returns nil for an out-of-range index" do
      m = %Model{command_mode: true, command_input: "xyzzy", command_selected: 0}
      assert Model.selected_command(m) == nil
    end
  end
end
