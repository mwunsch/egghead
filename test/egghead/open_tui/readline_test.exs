defmodule Egghead.OpenTUI.ReadlineTest do
  use ExUnit.Case, async: true

  alias Egghead.OpenTUI.Readline

  describe "insert/3" do
    test "inserts at the cursor and advances by length" do
      assert Readline.insert("hp", 1, "el") == {"help", 3}
    end

    test "insert at end" do
      assert Readline.insert("foo", 3, "bar") == {"foobar", 6}
    end

    test "insert at start" do
      assert Readline.insert("bar", 0, "foo") == {"foobar", 3}
    end
  end

  describe "delete_before/2" do
    test "removes the character before the cursor" do
      assert Readline.delete_before("help", 4) == {"hel", 3}
    end

    test "removes from the middle" do
      assert Readline.delete_before("help", 2) == {"hlp", 1}
    end

    test "no-op at the start" do
      assert Readline.delete_before("help", 0) == {"help", 0}
    end
  end

  describe "kill_to_eol/2" do
    test "deletes from cursor to end" do
      assert Readline.kill_to_eol("hello world", 5) == {"hello", 5}
    end

    test "no-op at end" do
      assert Readline.kill_to_eol("hi", 2) == {"hi", 2}
    end
  end

  describe "kill_to_bol/2" do
    test "deletes from start to cursor and resets cursor" do
      assert Readline.kill_to_bol("hello world", 5) == {" world", 0}
    end
  end

  describe "kill_word/2" do
    test "kills the previous word" do
      assert Readline.kill_word("hello world", 11) == {"hello ", 6}
    end

    test "skips trailing whitespace before killing" do
      assert Readline.kill_word("hello   ", 8) == {"", 0}
    end
  end

  describe "kill_word_forward/2" do
    test "kills the next word" do
      assert Readline.kill_word_forward("hello world", 0) == {" world", 0}
    end
  end

  describe "cursor movement" do
    test "move_to_start" do
      assert Readline.move_to_start("hello", 3) == {"hello", 0}
    end

    test "move_to_end" do
      assert Readline.move_to_end("hello", 0) == {"hello", 5}
    end

    test "move_left clamps at 0" do
      assert Readline.move_left("hi", 0) == {"hi", 0}
    end

    test "move_right clamps at end" do
      assert Readline.move_right("hi", 2) == {"hi", 2}
    end

    test "move_word_left jumps over the previous word" do
      assert Readline.move_word_left("hello world", 11) == {"hello world", 6}
    end

    test "move_word_right jumps over the next word" do
      assert Readline.move_word_right("hello world", 0) == {"hello world", 5}
    end
  end

  describe "round-trip composition" do
    test "type, move, edit produce expected text" do
      {text, cursor} = {"", 0}
      {text, cursor} = Readline.insert(text, cursor, "hello")
      {text, cursor} = Readline.insert(text, cursor, " ")
      {text, cursor} = Readline.insert(text, cursor, "world")
      assert {text, cursor} == {"hello world", 11}

      {text, cursor} = Readline.move_word_left(text, cursor)
      assert cursor == 6

      {text, cursor} = Readline.kill_to_eol(text, cursor)
      assert {text, cursor} == {"hello ", 6}

      {text, cursor} = Readline.delete_before(text, cursor)
      assert {text, cursor} == {"hello", 5}
    end
  end
end
