defmodule Egghead.Eval.ScorerTest do
  use ExUnit.Case, async: true

  alias Egghead.Eval.{Scorer, Task}

  defp research_task(milestones \\ []) do
    %Task{
      id: "research/test",
      category: :research,
      milestones: milestones,
      prompt: "Collaborate on a research proposal.",
      dialogue_mode: :open,
      required_capabilities: ["records.read"]
    }
  end

  defp transcript_msg(agent_id, text) do
    %{
      sender: %{type: :agent, name: agent_id, id: agent_id},
      content: text,
      timestamp: DateTime.utc_now()
    }
  end

  defp judge_responses(responses) do
    # `responses` is a list of strings — one per judge call, in order.
    # Returns a judge_fun closure that hands them out round-robin.
    {:ok, agent} =
      Agent.start_link(fn -> responses end)

    fn _prompt ->
      case Agent.get_and_update(agent, fn
             [] -> {:exhausted, []}
             [h | t] -> {h, t}
           end) do
        :exhausted -> {:error, :no_more_stub_responses}
        response -> {:ok, response}
      end
    end
  end

  describe "grade/3 (research task, mocked judge)" do
    test "computes KPI = 1.0 when every agent contributes to every milestone" do
      transcript = [transcript_msg("a", "hi"), transcript_msg("b", "hello")]

      milestones_json = ~s|[
        {"milestone": "m1", "agents": ["a","b"]},
        {"milestone": "m2", "agents": ["a","b"]}
      ]|

      judge_fun =
        judge_responses([
          milestones_json,
          ~s|{"rating": 5}|,
          ~s|{"rating": 4}|,
          ~s|{"innovation": 4, "safety": 5, "feasibility": 3}|
        ])

      {:ok, score} =
        Scorer.grade(research_task(), transcript,
          roster: ["a", "b"],
          judge_fun: judge_fun
        )

      assert score.kpi == 1.0
      assert score.communication == 5
      assert score.planning == 4
      assert score.task_specific["innovation"] == 4
      assert score.task_specific["safety"] == 5
      assert score.task_specific["feasibility"] == 3
      assert score.per_agent["a"].achieved == 2
      assert score.per_agent["b"].achieved == 2
    end

    test "computes KPI = 0.5 when each agent hits exactly one milestone" do
      transcript = [transcript_msg("a", "x"), transcript_msg("b", "y")]

      milestones_json = ~s|[
        {"milestone": "m1", "agents": ["a"]},
        {"milestone": "m2", "agents": ["b"]}
      ]|

      judge_fun =
        judge_responses([
          milestones_json,
          ~s|{"rating": 3}|,
          ~s|{"rating": 3}|,
          ~s|{"innovation": 2, "safety": 4, "feasibility": 3}|
        ])

      {:ok, score} =
        Scorer.grade(research_task(), transcript,
          roster: ["a", "b"],
          judge_fun: judge_fun
        )

      assert score.kpi == 0.5
      assert score.per_agent["a"].fraction == 0.5
      assert score.per_agent["b"].fraction == 0.5
    end

    test "returns 0 KPI for an empty milestone array" do
      transcript = [transcript_msg("a", "x")]

      judge_fun =
        judge_responses([
          ~s|[]|,
          ~s|{"rating": 1}|,
          ~s|{"rating": 1}|,
          ~s|{"innovation": 1, "safety": 1, "feasibility": 1}|
        ])

      {:ok, score} =
        Scorer.grade(research_task(), transcript,
          roster: ["a"],
          judge_fun: judge_fun
        )

      assert score.kpi == 0.0
      assert score.milestones == []
    end

    test "strips code fences from judge output before parsing" do
      transcript = [transcript_msg("a", "hi")]

      fenced = "```json\n[{\"milestone\": \"m\", \"agents\": [\"a\"]}]\n```"

      judge_fun =
        judge_responses([
          fenced,
          ~s|{"rating": 4}|,
          ~s|{"rating": 4}|,
          ~s|{"innovation": 4, "safety": 4, "feasibility": 4}|
        ])

      {:ok, score} =
        Scorer.grade(research_task(), transcript,
          roster: ["a"],
          judge_fun: judge_fun
        )

      assert score.kpi == 1.0
    end

    test "invalid milestone JSON bubbles up as an error" do
      transcript = [transcript_msg("a", "hi")]
      judge_fun = judge_responses([~s|not json|])

      assert {:error, _} =
               Scorer.grade(research_task(), transcript,
                 roster: ["a"],
                 judge_fun: judge_fun
               )
    end

    test "bargaining category wires buyer+seller prompts through task_specific" do
      bargaining_task = %Task{
        id: "bargaining/test",
        category: :bargaining,
        milestones: [],
        prompt: "Negotiate.",
        dialogue_mode: :open
      }

      transcript = [transcript_msg("buyer", "offer"), transcript_msg("seller", "counter")]

      judge_fun =
        judge_responses([
          ~s|[{"milestone": "buyer offered", "agents": ["buyer"]}]|,
          ~s|{"rating": 4}|,
          ~s|{"rating": 3}|,
          ~s|{"seller": {"effectiveness_of_strategies": 4, "progress_and_outcome": 3, "interaction_dynamics": 5}}|,
          ~s|{"buyer": {"effectiveness_of_strategies": 3, "progress_and_outcome": 4, "interaction_dynamics": 4}}|
        ])

      {:ok, score} =
        Scorer.grade(bargaining_task, transcript,
          roster: ["buyer", "seller"],
          judge_fun: judge_fun
        )

      assert score.kpi > 0
      assert Map.has_key?(score.task_specific, "seller")
      assert Map.has_key?(score.task_specific, "buyer")
      assert score.task_specific["seller"]["effectiveness_of_strategies"] == 4
      assert score.task_specific["buyer"]["interaction_dynamics"] == 4
    end

    test "tolerates missing communication / planning / task-specific responses" do
      transcript = [transcript_msg("a", "hi")]

      judge_fun =
        judge_responses([
          ~s|[{"milestone": "m", "agents": ["a"]}]|,
          "not-json-either",
          "also-bad",
          "nope"
        ])

      {:ok, score} =
        Scorer.grade(research_task(), transcript,
          roster: ["a"],
          judge_fun: judge_fun
        )

      assert score.kpi == 1.0
      assert score.communication == nil
      assert score.planning == nil
      assert score.task_specific == %{}
    end
  end
end
