defmodule Egghead.TUI.Chat.PasteTest do
  use ExUnit.Case, async: true

  alias Egghead.TUI.Chat.Paste

  describe "chip_worthy?/1" do
    test "false for short single-line text" do
      refute Paste.chip_worthy?("hello world")
    end

    test "true for >150 chars on a single line" do
      assert Paste.chip_worthy?(String.duplicate("x", 200))
    end

    test "true for >3 lines even if short" do
      assert Paste.chip_worthy?("a\nb\nc\nd\ne")
    end

    test "false for exactly 3 lines of short text" do
      refute Paste.chip_worthy?("a\nb\nc")
    end
  end

  describe "build/2" do
    test "captures id and full_text verbatim" do
      text = "def foo do\n  :bar\nend"
      p = Paste.build(7, text)
      assert p.id == 7
      assert p.full_text == text
    end

    test "head_preview clips to ~25 chars at a word boundary with ellipsis" do
      text = "the quick brown fox jumps over the lazy dog"
      p = Paste.build(1, text)
      assert String.ends_with?(p.head, "…")
      assert String.length(p.head) <= 26
    end

    test "head_preview falls back to (empty) for whitespace-only" do
      p = Paste.build(1, "   \n\n  ")
      assert p.head == "(empty)"
    end

    test "line_count is the count of newlines" do
      assert Paste.build(1, "single").line_count == 0
      assert Paste.build(1, "a\nb\nc").line_count == 2
    end
  end

  describe "display/1" do
    test "single line shows the head with a trailing ellipsis" do
      p = Paste.build(1, "hello")
      assert Paste.display(p) == "hello…"
    end

    test "multi-line appends '+N lines' after the ellipsis" do
      p = Paste.build(1, "first\nsecond\nthird")
      assert Paste.display(p) == "first… +2 lines"
    end
  end

  describe "head_segment/1 and tail_segment/1" do
    test "head_segment is `📋 head…`" do
      p = Paste.build(1, "hi")
      assert Paste.head_segment(p) == "📋 hi…"
    end

    test "tail_segment is nil for single-line pastes" do
      p = Paste.build(1, "hi")
      assert Paste.tail_segment(p) == nil
    end

    test "tail_segment is ' +N lines' for multi-line pastes" do
      p = Paste.build(1, "a\nb\nc")
      assert Paste.tail_segment(p) == " +2 lines"
    end
  end
end
