defmodule Egghead.Record.DeliberationTest do
  use ExUnit.Case, async: true

  alias Egghead.Record
  alias Egghead.Record.Deliberation

  defp record(opts) do
    %Record{
      id: Keyword.get(opts, :id, "deliberation/agents/scout/xyz"),
      title: Keyword.get(opts, :title, "Deliberation: Scout — 2026-04-19"),
      body: Keyword.get(opts, :body, "Summary of prior reasoning."),
      class: :deliberation,
      author: Keyword.get(opts, :author, "agents/scout"),
      tags:
        Keyword.get(opts, :tags, [
          "deliberation",
          "agent:agents/scout",
          "room:team-standup"
        ]),
      links: Keyword.get(opts, :links, []),
      wikilinks: Keyword.get(opts, :wikilinks, []),
      updated: Keyword.get(opts, :updated, "2026-04-19T12:00:00Z"),
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  describe "from/1" do
    test "projects a deliberation record with all fields populated" do
      rec =
        record(
          id: "deliberation/agents/scout/abc123",
          author: "agents/scout",
          tags: ["deliberation", "agent:agents/scout", "room:team-standup"],
          links: ["design/foo"],
          wikilinks: [%{target: "research/bar", display: nil, fragment: nil}],
          body: "Distilled reasoning."
        )

      projection = Deliberation.from(rec)

      assert projection.record_id == "deliberation/agents/scout/abc123"
      assert projection.agent_id == "agents/scout"
      assert projection.room_id == "team-standup"
      assert projection.body == "Distilled reasoning."
      assert "design/foo" in projection.referenced_records
      assert "research/bar" in projection.referenced_records
    end

    test "falls back to agent tag when author is nil" do
      rec =
        record(
          author: nil,
          tags: ["deliberation", "agent:agents/heckler", "room:xyz"]
        )

      assert Deliberation.from(rec).agent_id == "agents/heckler"
    end

    test "returns nil room_id when no `room:` tag present" do
      rec = record(tags: ["deliberation", "agent:agents/scout"])
      assert Deliberation.from(rec).room_id == nil
    end

    test "gracefully handles empty tags/links/body" do
      rec =
        %Record{
          id: "deliberation/foo",
          class: :deliberation,
          author: nil,
          tags: [],
          links: [],
          wikilinks: [],
          meta: %{},
          body: ""
        }

      projection = Deliberation.from(rec)
      assert projection.agent_id == nil
      assert projection.room_id == nil
      assert projection.referenced_records == []
      assert projection.body == ""
    end
  end

  describe "context_for_session/2" do
    test "formats a preview block with the record id" do
      rec = record(id: "deliberation/agents/scout/abc", body: "Short body.")
      out = Deliberation.context_for_session(rec)

      assert out =~ "Prior context (from deliberation/agents/scout/abc):"
      assert out =~ "Short body."
    end

    test "truncates long bodies with ellipsis" do
      long_body = String.duplicate("x", 800)
      rec = record(body: long_body)

      out = Deliberation.context_for_session(rec, max_chars: 200)

      assert String.ends_with?(out, "...")
      # 200-char slice + marker + the "Prior context" preamble.
      assert String.length(out) < String.length(long_body)
    end

    test "honors a custom max_chars" do
      rec = record(body: String.duplicate("a", 100))
      out = Deliberation.context_for_session(rec, max_chars: 50)
      assert out =~ "..."
    end

    test "accepts a projection as well as a record" do
      projection = Deliberation.from(record(body: "Hi."))
      out = Deliberation.context_for_session(projection)
      assert out =~ "Hi."
    end
  end
end
