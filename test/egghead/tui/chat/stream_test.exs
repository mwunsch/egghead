defmodule Egghead.TUI.Chat.StreamTest do
  use ExUnit.Case, async: true

  alias Egghead.TUI.Chat.{Entry, Stream}

  describe "append/2" do
    test "buffers a partial line without committing" do
      {s, committed} = Stream.new("agents/scout", "Scout") |> Stream.append("hello")
      assert committed == []
      assert s.current == "hello"
      assert Stream.has_text?(s)
    end

    test "commits on \\n and keeps the trailing fragment" do
      {s, committed} =
        Stream.new("agents/scout", "Scout")
        |> Stream.append("line one\nline two")

      assert [%Entry{kind: :agent, sender_name: "Scout", text: "line one"}] = committed
      assert s.current == "line two"
    end

    test "multiple deltas accumulate then commit on a later \\n" do
      s0 = Stream.new("agents/scout", "Scout")
      {s1, c1} = Stream.append(s0, "first ")
      {s2, c2} = Stream.append(s1, "line")
      {s3, c3} = Stream.append(s2, "\nsecond ")
      {s4, c4} = Stream.append(s3, "line\n")

      assert c1 == []
      assert c2 == []
      assert [%Entry{text: "first line"}] = c3
      assert [%Entry{text: "second line"}] = c4
      assert s4.current == ""
    end

    test "blank lines (\\n\\n) commit with empty strings filtered out" do
      {_s, committed} =
        Stream.new("a", "A") |> Stream.append("para one\n\npara two\n")

      # Empty line between paragraphs is filtered out by Enum.reject
      assert [%Entry{text: "para one"}, %Entry{text: "para two"}] = committed
    end

    test "drops empty entries from triple-newline burst" do
      {_s, committed} =
        Stream.new("a", "A") |> Stream.append("line\n\n\nnext")

      assert [%Entry{text: "line"}] = committed
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
