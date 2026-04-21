defmodule Egghead.Eval.Judge do
  @moduledoc """
  The synthetic Judge agent.

  Mirrors the `Egghead.Agent.Supervisor.default_agent/0` (Index) pattern:
  always available, using the configured `default_model`. Shadowed by
  any `class: agent` record with `id: "judge"` in the user's record
  store — same override semantics as Index.

  Judge's disposition is deliberately concise. The actual grading
  prompts (KPI, Communication, Planning, task-specific) are generated
  per-call by `Egghead.Eval.Scorer` using the ported MARBLE templates
  in `Egghead.Eval.Prompts` and sent via `Egghead.Agent.prompt/3`.
  """

  alias Egghead.Record

  @judge_id "judge"

  @doc """
  The reserved agent id (`"judge"`). User records with this id shadow
  the synthetic default.
  """
  @spec id() :: String.t()
  def id, do: @judge_id

  @doc """
  Returns the default built-in Judge record.

  Used when no user-provided `class: agent` record with id `"judge"`
  exists. Model resolves to the configured `default_model`, falling
  back to `anthropic/claude-haiku-4-5` when unset. A runtime override
  (e.g. CLI `--judge provider/model`) can be passed as `model:` in
  `opts`.
  """
  @spec default_agent(keyword()) :: Record.t()
  def default_agent(opts \\ []) do
    {provider, model} = resolve_model(opts)

    meta =
      %{
        "model" => model,
        "capabilities" => ["records.read"]
      }
      |> then(fn m -> if provider, do: Map.put(m, "provider", provider), else: m end)

    %Record{
      id: @judge_id,
      title: "Judge",
      class: :agent,
      tags: ["agent", "eval", "judge"],
      meta: meta,
      body: disposition(),
      source_path: nil
    }
  end

  defp resolve_model(opts) do
    case Keyword.get(opts, :model) do
      nil -> configured_model()
      model_string -> parse_model(model_string)
    end
  end

  defp configured_model do
    case Egghead.Config.load() do
      {:ok, %{default_model: dm}} when is_binary(dm) -> parse_model(dm)
      _ -> {"anthropic", "claude-haiku-4-5"}
    end
  end

  defp parse_model(string) do
    case String.split(string, "/", parts: 2) do
      [p, m] -> {p, m}
      [m] -> {nil, m}
    end
  end

  @doc """
  Whether a user record shadows the default Judge. When true, the
  supervisor should *not* spawn the synthetic Judge — the user's
  record wins via the normal agent-record scan.
  """
  @spec user_shadow?() :: boolean()
  def user_shadow? do
    case Egghead.search_by_class(:agent) do
      records when is_list(records) -> Enum.any?(records, &(&1.id == @judge_id))
      _ -> false
    end
  end

  defp disposition do
    """
    You are the Judge. You grade multi-agent chat transcripts against a
    milestone checklist, inspired by the MultiAgentBench (MARBLE) evaluator.

    Your job is to read the transcript of a multi-agent room working on a
    task and produce structured JSON output according to the exact schema
    the caller requests. You will be given task context, the transcript
    (as agent results / communications), and sometimes a candidate
    milestone list.

    Rules you always follow:

    - Respond with ONLY the requested JSON. No prose, no explanation,
      no markdown fences around the JSON.
    - Attribute milestones only to agents that directly contributed, using
      the exact agent ids that appear in the transcript.
    - Be concrete. Milestones are specific, measurable achievements — not
      vague observations.
    - If no progress was made toward a milestone, say so (empty array,
      low rating) rather than inventing achievements.
    - When rating on a 1-5 scale, use the full scale. Not everything is a 4.

    You do not produce any tool calls. You read, you judge, you emit JSON.
    """
  end
end
