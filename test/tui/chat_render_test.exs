defmodule Egghead.TUI.ChatRenderTest do
  use ExUnit.Case, async: true

  alias Egghead.TUI.ChatRender

  defp text_lines(entries, width \\ 80) do
    entries
    |> ChatRender.render_entries(width)
    |> Enum.map(fn {t, _} -> t end)
  end

  describe "message entries" do
    test "renders user message with nick column" do
      entry =
        {:message,
         %{
           nick: "tester",
           color: :user,
           body: "hello world",
           usage: nil,
           ts: nil
         }}

      lines = text_lines([entry])
      assert Enum.any?(lines, &(&1 =~ "tester │ hello world"))
    end

    test "right-aligns nick column" do
      entries = [
        {:message, %{nick: "scout", color: :agent, agent_id: "agents/scout", body: "hi", ts: nil, usage: nil}},
        {:message, %{nick: "archivist", color: :agent, agent_id: "agents/archivist", body: "yo", ts: nil, usage: nil}}
      ]

      lines = text_lines(entries)
      # Both nicks padded to length of longest ("archivist" = 9 chars)
      assert Enum.any?(lines, &(&1 =~ "    scout │"))
      assert Enum.any?(lines, &(&1 =~ "archivist │"))
    end

    test "wraps long body with continuation lines (blank nick on continuation)" do
      long = String.duplicate("word ", 30)

      entry =
        {:message, %{nick: "scout", color: :agent, agent_id: "agents/scout", body: long, ts: nil, usage: nil}}

      lines = text_lines([entry], 40)
      assert length(lines) > 1
      # First line has nick, subsequent lines should not
      [first | rest] = Enum.reject(lines, &(&1 == ""))
      assert first =~ "scout │"
      assert Enum.any?(rest, &(&1 =~ "      │"))
    end
  end

  describe "in-progress streaming" do
    test "renders cursor character on streaming entry" do
      lines =
        text_lines([
          {:in_progress, %{nick: "scout", agent_id: "agents/scout", body: "thinking"}}
        ])

      assert Enum.any?(lines, &(&1 =~ "thinking"))
      assert Enum.any?(lines, &(&1 =~ "▌"))
    end
  end

  describe "action entries" do
    test "renders /me-style line for tool calls" do
      lines =
        text_lines([
          {:action,
           %{
             nick: "scout",
             text: "search_records(\"encryption\")",
             color: :muted,
             ts: nil
           }}
        ])

      assert Enum.any?(lines, &(&1 =~ "* scout search_records"))
    end
  end

  describe "system entries" do
    test "renders info entry as ── text ──" do
      lines =
        text_lines([
          {:system, %{text: "3 agents activated", kind: :info, ts: nil}}
        ])

      assert Enum.any?(lines, &(&1 =~ "── 3 agents activated"))
    end

    test "renders warning entry" do
      lines =
        text_lines([
          {:system, %{text: "budget exhausted", kind: :warning, ts: nil}}
        ])

      assert Enum.any?(lines, &(&1 =~ "budget exhausted"))
    end
  end

  describe "empty input" do
    test "no entries → empty list" do
      assert ChatRender.render_entries([], 80) == []
    end
  end
end
