defmodule Egghead.Eval.ReporterTest do
  use ExUnit.Case, async: true

  alias Egghead.Eval.{Reporter, Scorer, Task}

  defp task do
    %Task{
      id: "research/example",
      category: :research,
      milestones: [],
      prompt: "Collaborate.",
      dialogue_mode: :open
    }
  end

  defp score do
    %Scorer.Score{
      kpi: 0.5,
      communication: 4,
      planning: 3,
      task_specific: %{"innovation" => 3, "safety" => 5, "feasibility" => 4},
      milestones: [
        %{"milestone" => "Identified sources", "agents" => ["a", "b"]},
        %{"milestone" => "Proposed direction", "agents" => ["a"]},
        %{"milestone" => "Cited prior work", "agents" => []}
      ],
      per_agent: %{
        "a" => %{achieved: 2, total: 3, fraction: 2 / 3},
        "b" => %{achieved: 1, total: 3, fraction: 1 / 3}
      }
    }
  end

  defp opts do
    %{
      run_id: "2026-04-20-abcd",
      task: task(),
      score: score(),
      roster: ["a", "b"],
      transcript_id: "chat/eval-2026-04-20-abcd",
      duration_ms: 123_000,
      turns: 5,
      roster_mode: :task,
      judge_model: "anthropic/claude-haiku-4-5"
    }
  end

  test "body renders milestones as GFM task list" do
    body = Reporter.body(opts())

    assert body =~ "- [x] Identified sources"
    assert body =~ "- [x] Proposed direction"
    assert body =~ "- [ ] Cited prior work"
  end

  test "body includes per-agent contribution bars" do
    body = Reporter.body(opts())

    assert body =~ "a "
    assert body =~ "b "
    assert body =~ "█"
    assert body =~ "░"
  end

  test "body shows all score dimensions in header" do
    body = Reporter.body(opts())

    assert body =~ "KPI:"
    assert body =~ "0.50"
    assert body =~ "Communication:"
    assert body =~ "4/5"
    assert body =~ "Planning:"
    assert body =~ "3/5"
    assert body =~ "Innovation"
    assert body =~ "Feasibility"
  end

  test "body attributes achieved milestones with footnote refs" do
    body = Reporter.body(opts())

    assert body =~ "[^m1]"
    assert body =~ "[^m2]"
    # m3 is unachieved, so no footnote ref on its line
    refute body =~ "[^m3]"

    # Footnote bodies are appended at the end
    assert body =~ "[^m1]: Achieved by a, b"
    assert body =~ "[^m2]: Achieved by a"
  end

  test "body includes a transcript pointer" do
    body = Reporter.body(opts())
    assert body =~ "[[chat/eval-2026-04-20-abcd]]"
  end

  test "to_record_attrs returns a create_record-compatible map" do
    attrs = Reporter.to_record_attrs(opts())

    assert attrs["id"] == "eval-runs/2026-04-20-abcd"
    assert attrs["class"] == "durable"
    assert "eval" in attrs["tags"]
    assert "run" in attrs["tags"]
    assert "research" in attrs["tags"]
    assert attrs["author"] == "judge"
    assert attrs["meta"]["kpi"] == 0.5
    assert attrs["meta"]["communication"] == 4
    assert attrs["meta"]["roster_mode"] == "task"
    assert attrs["meta"]["task"] == "research/example"

    # Task-specific scores bubble up into frontmatter meta
    assert attrs["meta"]["innovation"] == 3
    assert attrs["meta"]["feasibility"] == 4

    assert "eval-task:research/example" in attrs["links"]
  end

  test "renders an empty-milestones run without crashing" do
    empty_score = %{score() | milestones: [], per_agent: %{}}
    body = Reporter.body(%{opts() | score: empty_score})

    assert body =~ "_No milestones achieved._"
    assert body =~ "(no agents)"
  end
end
