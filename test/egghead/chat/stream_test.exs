defmodule Egghead.Chat.StreamTest do
  use ExUnit.Case, async: true

  alias Egghead.Chat.Stream
  alias Egghead.TUI.Chat.Entry

  describe "append/2 — TUI defaults (commit_on \\n, no trim)" do
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

      assert [%Entry{text: "para one"}, %Entry{text: "para two"}] = committed
    end

    test "drops empty entries from triple-newline burst" do
      {_s, committed} =
        Stream.new("a", "A") |> Stream.append("line\n\n\nnext")

      assert [%Entry{text: "line"}] = committed
    end

    test "preserves leading/trailing whitespace on committed lines (no trim)" do
      {_s, committed} =
        Stream.new("a", "A") |> Stream.append("  indented code\nnext")

      assert [%Entry{text: "  indented code"}] = committed
    end
  end

  describe "append/2 — LiveView mode (commit_on \\n\\n, trim: true)" do
    test "does not commit on single \\n" do
      {s, committed} =
        Stream.new("a", "A", commit_on: "\n\n", trim: true)
        |> Stream.append("line one\nline two")

      assert committed == []
      assert s.current == "line one\nline two"
    end

    test "commits whole paragraph on \\n\\n, trimmed" do
      {s, committed} =
        Stream.new("a", "A", commit_on: "\n\n", trim: true)
        |> Stream.append("  first para  \n\n  second")

      assert [%Entry{text: "first para"}] = committed
      assert s.current == "  second"
    end

    test "trim filters out paragraph that was only whitespace" do
      {_s, committed} =
        Stream.new("a", "A", commit_on: "\n\n", trim: true)
        |> Stream.append("   \n\nreal text")

      assert committed == []
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

    test "returns [] when trim leaves buffer empty" do
      s = Stream.new("a", "A", trim: true)
      {s, _} = Stream.append(s, "   ")
      assert Stream.finalize(s) == []
    end
  end

  describe "finalize_and_drop/2" do
    test "returns empty list and unchanged map when agent absent" do
      {streams, committed} = Stream.finalize_and_drop(%{}, "agents/scout")
      assert streams == %{}
      assert committed == []
    end

    test "flushes buffered text and removes the agent from the map" do
      s = Stream.new("agents/scout", "Scout")
      {s, _} = Stream.append(s, "partial")
      streams = %{"agents/scout" => s}

      {streams, committed} = Stream.finalize_and_drop(streams, "agents/scout")

      assert [%Entry{text: "partial"}] = committed
      assert streams == %{}
    end

    test "leaves other agents' streams intact" do
      s1 = Stream.new("a1", "A1")
      {s1, _} = Stream.append(s1, "x")
      s2 = Stream.new("a2", "A2")
      {s2, _} = Stream.append(s2, "y")
      streams = %{"a1" => s1, "a2" => s2}

      {streams, _committed} = Stream.finalize_and_drop(streams, "a1")

      assert Map.keys(streams) == ["a2"]
    end
  end
end
