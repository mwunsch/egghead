defmodule Egghead.TUI.Chat.MentionsTest do
  use ExUnit.Case, async: true

  alias Egghead.OpenTUI.EditBuffer
  alias Egghead.TUI.Chat.Mentions
  alias Egghead.TUI.Chat.Mentions.Context

  defp buf(text), do: EditBuffer.from_text(text)

  describe "detect/1" do
    test "no sigil → nil" do
      assert Mentions.detect(buf("hello world")) == nil
    end

    test "@ at start of line returns an :agent context" do
      assert %Context{kind: :agent, prefix: "sc"} = Mentions.detect(buf("@sc"))
    end

    test "@ after a space returns an :agent context" do
      assert %Context{kind: :agent, prefix: "scout"} = Mentions.detect(buf("hi @scout"))
    end

    test "@ in the middle of a word does not trigger (email-like)" do
      assert Mentions.detect(buf("me@example")) == nil
    end

    test "[[ open returns a :record context" do
      assert %Context{kind: :record, prefix: "des"} = Mentions.detect(buf("see [[des"))
    end

    test "[[ followed by ]] cuts off the scan" do
      assert Mentions.detect(buf("see [[done]] now ")) == nil
    end

    test "single [ does not trigger" do
      assert Mentions.detect(buf("[lone")) == nil
    end

    test "single [ at start of line does not trigger (Enum.at -1 wrap-around regression)" do
      assert Mentions.detect(buf("[")) == nil
    end

    test "captures slash and dash and dot in ids" do
      assert %Context{kind: :agent, prefix: "agents/sc-1.0"} =
               Mentions.detect(buf("@agents/sc-1.0"))
    end
  end

  describe "rank_agents/3" do
    setup do
      agents = [
        %{id: "agents/scout", name: "Scout"},
        %{id: "agents/scribe", name: "Scribe"},
        %{id: "agents/index", name: "Index"}
      ]

      {:ok, agents: agents}
    end

    test "filters by basename prefix, case-insensitive, preserving input order", %{agents: agents} do
      # Input order: scout, scribe (index comes after, doesn't match "sc")
      assert [%{id: "agents/scout"}, %{id: "agents/scribe"}] = Mentions.rank_agents(agents, "sc")
    end

    test "empty prefix matches everything with broadcast tokens prepended", %{agents: agents} do
      # Broadcast tokens (@everyone, @jam) are surfaced alongside real agents.
      result = Mentions.rank_agents(agents, "")

      assert [
               %{id: "everyone", kind: :broadcast},
               %{id: "jam", kind: :broadcast},
               %{id: "agents/scout"},
               %{id: "agents/scribe"},
               %{id: "agents/index"}
             ] = result
    end

    test "broadcast tokens match their prefix", %{agents: agents} do
      assert [%{id: "everyone", kind: :broadcast}] = Mentions.rank_agents(agents, "every")
      assert [%{id: "jam", kind: :broadcast}] = Mentions.rank_agents(agents, "ja")
    end

    test "non-matching prefix returns []", %{agents: agents} do
      assert Mentions.rank_agents(agents, "zzz") == []
    end

    test "respects :limit", %{agents: agents} do
      # Broadcast tokens count toward the limit.
      assert length(Mentions.rank_agents(agents, "", limit: 2)) == 2
    end
  end

  describe "rank_records/3" do
    setup do
      records = [
        %{id: "design/coordinator"},
        %{id: "design/chat-room"},
        %{id: "meta/session-log"}
      ]

      {:ok, records: records}
    end

    test "filters by full-id prefix, preserving input order", %{records: records} do
      # Input order: coordinator before chat-room
      assert [%{id: "design/coordinator"}, %{id: "design/chat-room"}] =
               Mentions.rank_records(records, "design/")
    end

    test "case-insensitive", %{records: records} do
      assert [_ | _] = Mentions.rank_records(records, "DESIGN/")
    end
  end

  describe "ghost_suffix/1" do
    test "empty when no candidates" do
      assert Mentions.ghost_suffix(%Context{kind: :agent, prefix: "sc", candidates: []}) == ""
    end

    test "for agents, returns the basename minus the prefix" do
      ctx = %Context{
        kind: :agent,
        prefix: "sc",
        candidates: [%{id: "agents/scout", name: "Scout"}]
      }

      assert Mentions.ghost_suffix(ctx) == "out"
    end

    test "for records, returns the id minus the prefix" do
      ctx = %Context{
        kind: :record,
        prefix: "design/coord",
        candidates: [%{id: "design/coordinator"}]
      }

      assert Mentions.ghost_suffix(ctx) == "inator"
    end
  end

  describe "selection / navigation" do
    setup do
      ctx = %Context{
        kind: :agent,
        prefix: "sc",
        candidates: [
          %{id: "agents/scout", name: "Scout"},
          %{id: "agents/scribe", name: "Scribe"}
        ]
      }

      {:ok, ctx: ctx}
    end

    test "default selection is 0", %{ctx: ctx} do
      assert ctx.selected == 0
    end

    test "move_down advances and wraps", %{ctx: ctx} do
      assert Mentions.move_down(ctx).selected == 1
      assert ctx |> Mentions.move_down() |> Mentions.move_down() |> Map.get(:selected) == 0
    end

    test "move_up wraps from top to bottom", %{ctx: ctx} do
      assert Mentions.move_up(ctx).selected == 1
    end

    test "ghost_suffix follows the selected candidate", %{ctx: ctx} do
      assert Mentions.ghost_suffix(ctx) == "out"
      assert ctx |> Mentions.move_down() |> Mentions.ghost_suffix() == "ribe"
    end

    test "accept inserts the selected candidate, not always the first", %{ctx: ctx} do
      b = buf("@sc")
      ctx2 = Mentions.move_down(ctx)
      b2 = Mentions.accept(b, ctx2)
      assert EditBuffer.to_text(b2) == "@agents/scribe"
    end
  end

  describe "accept/2" do
    test "no candidates → buffer unchanged" do
      b = buf("@sc")
      assert Mentions.accept(b, %Context{kind: :agent, prefix: "sc", candidates: []}) == b
    end

    test "agent: replaces sigil + prefix with an atomic token cell" do
      b = buf("hi @sc")

      ctx = %Context{
        kind: :agent,
        prefix: "sc",
        candidates: [%{id: "agents/scout", name: "Scout"}]
      }

      b2 = Mentions.accept(b, ctx)
      assert EditBuffer.to_text(b2) == "hi @agents/scout"

      # The token is a single cell, not 14 grapheme cells
      cells = EditBuffer.line_cells(b2, 0)
      token = Enum.find(cells, &match?(%Mentions.Token{}, &1))
      assert %Mentions.Token{kind: :agent, display: "@agents/scout"} = token
    end

    test "record: replaces sigil + prefix with an atomic token cell" do
      b = buf("see [[des")

      ctx = %Context{
        kind: :record,
        prefix: "des",
        candidates: [%{id: "design/coordinator"}]
      }

      b2 = Mentions.accept(b, ctx)
      assert EditBuffer.to_text(b2) == "see [[design/coordinator]]"

      cells = EditBuffer.line_cells(b2, 0)
      token = Enum.find(cells, &match?(%Mentions.Token{}, &1))
      assert %Mentions.Token{kind: :record, display: "[[design/coordinator]]"} = token
    end
  end
end
