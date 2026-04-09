defmodule Egghead.TUI.Chat.StreamTest do
  use ExUnit.Case, async: true

  alias Egghead.TUI.Chat.{Entry, Stream}

  describe "append/2" do
    test "buffers a partial paragraph without committing" do
      {s, committed} = Stream.new("agents/scout", "Scout") |> Stream.append("hello")
      assert committed == []
      assert s.current == "hello"
      assert Stream.has_text?(s)
    end

    test "preserves a single \\n inside the buffer (soft break)" do
      {s, committed} =
        Stream.new("agents/scout", "Scout")
        |> Stream.append("line one\nline two")

      assert committed == []
      assert s.current == "line one\nline two"
    end

    test "splits on \\n\\n into committed entries plus a remaining buffer" do
      {s, committed} =
        Stream.new("agents/scout", "Scout")
        |> Stream.append("para one\n\npara two so far")

      assert [%Entry{kind: :agent, sender_name: "Scout", text: "para one"}] = committed
      assert s.current == "para two so far"
    end

    test "multiple deltas accumulate then commit on a later \\n\\n" do
      s0 = Stream.new("agents/scout", "Scout")
      {s1, c1} = Stream.append(s0, "first ")
      {s2, c2} = Stream.append(s1, "para")
      {s3, c3} = Stream.append(s2, "\n\nsecond ")
      {s4, c4} = Stream.append(s3, "para\n\n")

      assert c1 == []
      assert c2 == []
      assert [%Entry{text: "first para"}] = c3
      assert [%Entry{text: "second para"}] = c4
      assert s4.current == ""
    end

    test "drops empty paragraphs from a triple-newline burst" do
      {_s, committed} =
        Stream.new("a", "A") |> Stream.append("para\n\n\n\nnext")

      assert [%Entry{text: "para"}] = committed
    end
  end

  describe "finalize/1" do
    test "flushes a non-empty current buffer as one trailing entry" do
      s = Stream.new("a", "A")
      {s, _} = Stream.append(s, "hello world")
      assert [%Entry{text: "hello world"}] = Stream.finalize(s)
    end

    test "returns [] when current is empty" do
      assert Stream.finalize(Stream.new("a", "A")) == []
    end
  end
end
