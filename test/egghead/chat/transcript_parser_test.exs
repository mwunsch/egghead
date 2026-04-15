defmodule Egghead.Chat.TranscriptParserTest do
  use ExUnit.Case, async: true

  alias Egghead.Chat.Room
  alias Egghead.Chat.Room.{Message, Sender}
  alias Egghead.Chat.TranscriptParser

  describe "round-trip" do
    test "format_transcript -> parse recovers user and agent messages" do
      original = [
        %Message{
          id: "m1",
          room_id: "r",
          sender: %Sender{type: :user, id: "m", name: "m"},
          content: "hello agents",
          timestamp: ~U[2026-04-15 18:55:45.507861Z],
          mentions: [],
          usage: nil
        },
        %Message{
          id: "m2",
          room_id: "r",
          sender: %Sender{type: :agent, id: "agents/scout", name: "Scout"},
          content: "/pass",
          timestamp: ~U[2026-04-15 18:55:47.140110Z],
          mentions: [],
          usage: nil
        },
        %Message{
          id: "m3",
          room_id: "r",
          sender: %Sender{type: :agent, id: "agents/archivist", name: "Archivist"},
          content: "Here's a multi-paragraph response.\n\nWith two paragraphs.",
          timestamp: ~U[2026-04-15 18:55:49.550693Z],
          mentions: [],
          usage: nil
        }
      ]

      body = Room.format_transcript(original)
      assert {:ok, parsed} = TranscriptParser.parse(body, "r")
      assert length(parsed) == 3

      [u, p, a] = parsed
      assert u.sender.type == :user
      assert u.sender.name == "m"
      assert u.content == "hello agents"

      assert p.sender.type == :agent
      assert p.sender.id == "agents/scout"
      assert p.content == "/pass"

      assert a.sender.id == "agents/archivist"
      assert a.content == "Here's a multi-paragraph response.\n\nWith two paragraphs."
    end

    test "empty body returns :no_messages" do
      assert {:error, :no_messages} = TranscriptParser.parse("", "r")
    end

    test "body without recognisable headers returns :no_messages" do
      assert {:error, :no_messages} = TranscriptParser.parse("just some prose", "r")
    end
  end
end
