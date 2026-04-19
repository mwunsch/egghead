defmodule Egghead.Record.TranscriptTest do
  use ExUnit.Case, async: true

  alias Egghead.Record
  alias Egghead.Record.Transcript

  defp record(opts) do
    %Record{
      id: opts[:id] || "chat/room-xyz",
      title: opts[:title] || "Chat: room-xyz",
      body: opts[:body] || "",
      class: :transcript,
      tags: opts[:tags] || ["chat", "transcript"],
      links: opts[:links] || [],
      meta: opts[:meta] || %{}
    }
  end

  describe "from/1" do
    test "projects a transcript record into typed config" do
      rec =
        record(
          id: "chat/team-2026-04-19",
          title: "Chat: team-2026-04-19",
          links: ["agents/scout", "agents/heckler"],
          body: "(messages here)"
        )

      projection = Transcript.from(rec)

      assert projection.record_id == "chat/team-2026-04-19"
      assert projection.room_id == "team-2026-04-19"
      assert projection.title == "Chat: team-2026-04-19"
      assert projection.participating_agents == ["agents/scout", "agents/heckler"]
      assert projection.body == "(messages here)"
    end

    test "derives room_id by stripping the `chat/` prefix" do
      assert Transcript.from(record(id: "chat/foo")).room_id == "foo"
    end

    test "falls through to raw id when no `chat/` prefix" do
      assert Transcript.from(record(id: "unprefixed")).room_id == "unprefixed"
    end

    test "handles empty links and body gracefully" do
      projection = Transcript.from(record(links: [], body: ""))
      assert projection.participating_agents == []
      assert projection.body == ""
    end
  end

  describe "messages/1" do
    test "parses body into structured messages" do
      body = """
      **alice** — 2026-04-19T13:00:00Z

      hello world

      **Scout** (`agents/scout`) — 2026-04-19T13:00:05Z

      hi there
      """

      projection = Transcript.from(record(body: body))
      assert {:ok, messages} = Transcript.messages(projection)
      assert length(messages) == 2
    end

    test "accepts a raw Record as well as a projection" do
      body = "**alice** — 2026-04-19T13:00:00Z\n\nhello\n"
      rec = record(body: body)

      assert {:ok, [_]} = Transcript.messages(rec)
    end
  end
end
