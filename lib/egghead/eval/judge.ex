defmodule Egghead.Eval.Judge do
  @moduledoc """
  The built-in Judge agent.

  Judge is a `quiet: true, idle: true` built-in defined in
  `priv/agents/judge.md`. It uses the configured `default_model` and
  is shadowed by any `class: agent` record with `id: "judge"` in the
  user's store.

  Judge's disposition is deliberately concise. The actual grading
  prompts (KPI, Communication, Planning, task-specific) are generated
  per-call by `Egghead.Eval.Scorer` using the ported MARBLE templates
  in `Egghead.Eval.Prompts` and sent via `Egghead.Agent.prompt/3`.
  """

  alias Egghead.Agent.Builtin
  alias Egghead.Record

  @judge_id "judge"

  @doc """
  The reserved agent id (`"judge"`). User records with this id shadow
  the built-in.
  """
  @spec id() :: String.t()
  def id, do: @judge_id

  @doc """
  Returns the built-in Judge record from `priv/agents/judge.md`.

  A runtime override (e.g. CLI `--judge provider/model`) can be passed
  as `model:` in `opts`; it lands in the record's meta map and the
  agent process resolves it normally at spawn time.
  """
  @spec default_agent(keyword()) :: Record.t() | nil
  def default_agent(opts \\ []) do
    case Builtin.fetch(@judge_id) do
      nil ->
        nil

      %Record{} = record ->
        case Keyword.get(opts, :model) do
          nil -> record
          model -> %Record{record | meta: Map.put(record.meta, "model", model)}
        end
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
end
