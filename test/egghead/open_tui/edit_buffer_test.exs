defmodule Egghead.OpenTUI.EditBufferTest do
  use ExUnit.Case, async: true

  alias Egghead.OpenTUI.EditBuffer

  describe "construction" do
    test "new/0 is empty with cursor at origin" do
      b = EditBuffer.new()
      assert b.lines == [""]
      assert EditBuffer.cursor(b) == {0, 0}
      assert EditBuffer.empty?(b)
    end

    test "from_text/1 splits on \\n and parks the cursor at the end" do
      b = EditBuffer.from_text("hi\nthere")
      assert b.lines == ["hi", "there"]
      assert EditBuffer.cursor(b) == {1, 5}
      refute EditBuffer.empty?(b)
    end

    test "to_text/1 round-trips" do
      text = "one\ntwo\nthree"
      assert text == text |> EditBuffer.from_text() |> EditBuffer.to_text()
    end

    test "clear/1 returns an empty buffer" do
      b = EditBuffer.from_text("hi") |> EditBuffer.clear()
      assert EditBuffer.empty?(b)
    end
  end

  describe "insertion" do
    test "insert/2 of a plain string appends at cursor" do
      b = EditBuffer.new() |> EditBuffer.insert("hello")
      assert EditBuffer.to_text(b) == "hello"
      assert EditBuffer.cursor(b) == {0, 5}
    end

    test "insert/2 of text containing \\n splits lines" do
      b = EditBuffer.new() |> EditBuffer.insert("ab\ncd")
      assert b.lines == ["ab", "cd"]
      assert EditBuffer.cursor(b) == {1, 2}
    end

    test "insert/2 mid-line preserves the suffix" do
      b =
        EditBuffer.from_text("ad")
        |> Map.put(:col, 1)
        |> EditBuffer.insert("bc")

      assert EditBuffer.to_text(b) == "abcd"
      assert EditBuffer.cursor(b) == {0, 3}
    end

    test "insert_newline/1 splits the current line at the cursor" do
      b =
        EditBuffer.from_text("abcd")
        |> Map.put(:col, 2)
        |> EditBuffer.insert_newline()

      assert b.lines == ["ab", "cd"]
      assert EditBuffer.cursor(b) == {1, 0}
    end

    test "paste/2 preserves embedded newlines (alias for insert/2)" do
      b = EditBuffer.new() |> EditBuffer.paste("first\nsecond")
      assert b.lines == ["first", "second"]
      assert EditBuffer.cursor(b) == {1, 6}
    end
  end

  describe "delete_before / backspace" do
    test "no-op at buffer start" do
      b = EditBuffer.new() |> EditBuffer.delete_before()
      assert b == EditBuffer.new()
    end

    test "deletes the previous grapheme within a line" do
      b =
        EditBuffer.from_text("abc")
        |> EditBuffer.delete_before()

      assert EditBuffer.to_text(b) == "ab"
      assert EditBuffer.cursor(b) == {0, 2}
    end

    test "joins lines when called at column 0" do
      b =
        EditBuffer.from_text("ab\ncd")
        |> Map.merge(%{row: 1, col: 0})
        |> EditBuffer.delete_before()

      assert b.lines == ["abcd"]
      assert EditBuffer.cursor(b) == {0, 2}
    end
  end

  describe "delete_after / forward-delete" do
    test "removes the grapheme under the cursor" do
      b =
        EditBuffer.from_text("abc")
        |> Map.put(:col, 1)
        |> EditBuffer.delete_after()

      assert EditBuffer.to_text(b) == "ac"
      assert EditBuffer.cursor(b) == {0, 1}
    end

    test "joins the next line when at end-of-line" do
      b =
        EditBuffer.from_text("ab\ncd")
        |> Map.merge(%{row: 0, col: 2})
        |> EditBuffer.delete_after()

      assert b.lines == ["abcd"]
      assert EditBuffer.cursor(b) == {0, 2}
    end

    test "no-op at end-of-buffer" do
      b = EditBuffer.from_text("ab")
      assert EditBuffer.delete_after(b) == b
    end
  end

  describe "horizontal cursor movement" do
    test "move_left/1 hops to the previous line at col 0" do
      b =
        EditBuffer.from_text("ab\ncd")
        |> Map.merge(%{row: 1, col: 0})
        |> EditBuffer.move_left()

      assert EditBuffer.cursor(b) == {0, 2}
    end

    test "move_right/1 hops to the next line at end-of-line" do
      b =
        EditBuffer.from_text("ab\ncd")
        |> Map.merge(%{row: 0, col: 2})
        |> EditBuffer.move_right()

      assert EditBuffer.cursor(b) == {1, 0}
    end

    test "move_left/1 at buffer start is a no-op" do
      b = EditBuffer.new()
      assert EditBuffer.move_left(b) == b
    end
  end

  describe "vertical cursor movement" do
    test "move_up/1 clamps the column to the new line length" do
      b =
        EditBuffer.from_text("a\nbcdef")
        |> Map.merge(%{row: 1, col: 4})
        |> EditBuffer.move_up()

      assert EditBuffer.cursor(b) == {0, 1}
    end

    test "move_up/1 at top row snaps to col 0" do
      b =
        EditBuffer.from_text("hello")
        |> Map.put(:col, 3)
        |> EditBuffer.move_up()

      assert EditBuffer.cursor(b) == {0, 0}
    end

    test "move_down/1 clamps the column" do
      b =
        EditBuffer.from_text("abcde\nxy")
        |> Map.merge(%{row: 0, col: 4})
        |> EditBuffer.move_down()

      assert EditBuffer.cursor(b) == {1, 2}
    end

    test "move_down/1 at the bottom snaps to end of last line" do
      b =
        EditBuffer.from_text("abc")
        |> Map.put(:col, 1)
        |> EditBuffer.move_down()

      assert EditBuffer.cursor(b) == {0, 3}
    end
  end

  describe "line / buffer endpoints" do
    test "move_to_line_start/1 and move_to_line_end/1" do
      b = EditBuffer.from_text("hello") |> Map.put(:col, 2)
      assert EditBuffer.cursor(EditBuffer.move_to_line_start(b)) == {0, 0}
      assert EditBuffer.cursor(EditBuffer.move_to_line_end(b)) == {0, 5}
    end

    test "move_to_buffer_start/end/1" do
      b = EditBuffer.from_text("ab\ncde\nfg")
      assert EditBuffer.cursor(EditBuffer.move_to_buffer_start(b)) == {0, 0}
      assert EditBuffer.cursor(EditBuffer.move_to_buffer_end(b)) == {2, 2}
    end
  end

  describe "word movement" do
    test "move_word_left within a line" do
      b =
        EditBuffer.from_text("foo bar")
        |> Map.put(:col, 7)
        |> EditBuffer.move_word_left()

      assert EditBuffer.cursor(b) == {0, 4}
    end

    test "move_word_left at col 0 hops to end of previous line" do
      b =
        EditBuffer.from_text("foo\nbar")
        |> Map.merge(%{row: 1, col: 0})
        |> EditBuffer.move_word_left()

      assert EditBuffer.cursor(b) == {0, 3}
    end

    test "move_word_right within a line" do
      b =
        EditBuffer.from_text("foo bar")
        |> Map.put(:col, 0)
        |> EditBuffer.move_word_right()

      assert EditBuffer.cursor(b) == {0, 3}
    end

    test "move_word_right at end-of-line hops to next line" do
      b =
        EditBuffer.from_text("foo\nbar")
        |> Map.merge(%{row: 0, col: 3})
        |> EditBuffer.move_word_right()

      assert EditBuffer.cursor(b) == {1, 0}
    end
  end

  describe "kill commands" do
    test "kill_to_eol/1 truncates the current line at the cursor" do
      b =
        EditBuffer.from_text("hello world")
        |> Map.put(:col, 5)
        |> EditBuffer.kill_to_eol()

      assert b.lines == ["hello"]
      assert EditBuffer.cursor(b) == {0, 5}
    end

    test "kill_to_bol/1 truncates the current line up to the cursor" do
      b =
        EditBuffer.from_text("hello world")
        |> Map.put(:col, 6)
        |> EditBuffer.kill_to_bol()

      assert b.lines == ["world"]
      assert EditBuffer.cursor(b) == {0, 0}
    end

    test "kill_line/1 deletes the current line, leaves the others" do
      b =
        EditBuffer.from_text("a\nb\nc")
        |> Map.merge(%{row: 1, col: 0})
        |> EditBuffer.kill_line()

      assert b.lines == ["a", "c"]
      assert EditBuffer.cursor(b) == {1, 0}
    end

    test "kill_line/1 on the only line clears the buffer" do
      b = EditBuffer.from_text("hello") |> EditBuffer.kill_line()
      assert EditBuffer.empty?(b)
    end

    test "kill_word/1 removes the previous word" do
      b =
        EditBuffer.from_text("foo bar")
        |> Map.put(:col, 7)
        |> EditBuffer.kill_word()

      assert b.lines == ["foo "]
      assert EditBuffer.cursor(b) == {0, 4}
    end

    test "kill_word/1 at column 0 falls back to delete_before (joins lines)" do
      b =
        EditBuffer.from_text("ab\ncd")
        |> Map.merge(%{row: 1, col: 0})
        |> EditBuffer.kill_word()

      assert b.lines == ["abcd"]
      assert EditBuffer.cursor(b) == {0, 2}
    end

    test "kill_word_forward/1 removes the next word" do
      b =
        EditBuffer.from_text("foo bar baz")
        |> Map.put(:col, 4)
        |> EditBuffer.kill_word_forward()

      assert b.lines == ["foo  baz"]
      assert EditBuffer.cursor(b) == {0, 4}
    end
  end

  describe "grapheme awareness" do
    test "insert + cursor counts wide graphemes as one position" do
      b = EditBuffer.new() |> EditBuffer.insert("héllo")
      assert EditBuffer.cursor(b) == {0, 5}
    end

    test "delete_before/1 deletes one full grapheme cluster" do
      b =
        EditBuffer.from_text("café")
        |> EditBuffer.delete_before()

      assert EditBuffer.to_text(b) == "caf"
    end
  end
end
