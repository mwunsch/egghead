defmodule Egghead.Eval do
  @moduledoc """
  Public API for Egghead's eval interface — inspired by MultiAgentBench
  (MARBLE). See `design/eval.md` in the user's record store for the
  full design.

  Peer to TUI / CLI / Web / MCP: runs multi-agent tasks against the
  agents defined in the user's record store (or against personas
  shipped with a task for MARBLE-benchmark comparability), grades the
  transcript with a Judge agent, and writes a durable run record.

  Usage in `iex`:

      Egghead.Eval.list_tasks()
      #=> [%Task{id: "research/profile-1", …}, …]

      {:ok, result} = Egghead.Eval.run("research/profile-1", roster: :task)
      result.score.kpi
      #=> 0.73

      Egghead.Eval.list_runs()
      #=> [%Egghead.Record{id: "eval-runs/…", …}]
  """

  alias Egghead.Eval.{Reporter, Runner, Task}

  @doc """
  Runs a single task end-to-end. Opts forwarded to `Runner.run/2`.
  """
  @spec run(String.t(), keyword()) :: {:ok, Runner.result()} | {:error, term()}
  defdelegate run(task_id, opts \\ []), to: Runner

  @doc """
  Lists tasks available in the bundled `priv/eval/tasks/` directory.
  """
  @spec list_tasks() :: [Task.t()]
  defdelegate list_tasks, to: Task, as: :list

  @doc """
  Lists durable run records previously produced by `run/2`.
  """
  @spec list_runs() :: [Egghead.Record.t()]
  def list_runs do
    Egghead.search_by_tag("eval")
    |> Enum.filter(&("run" in &1.tags))
  end

  @doc """
  Re-renders the report body for an existing run record without
  re-invoking the judge. Useful for reformatting after changes to the
  reporter.
  """
  @spec report(String.t()) :: {:ok, String.t()} | {:error, term()}
  def report(run_id) do
    record_id = normalize_run_id(run_id)

    case Egghead.get_record(record_id) do
      {:ok, record} -> {:ok, record.body}
      {:error, _} = err -> err
    end
  end

  @doc """
  Produces a side-by-side comparison of two run records as a durable
  `class: durable` record. Returns the new record.
  """
  @spec compare(String.t(), String.t()) :: {:ok, Egghead.Record.t()} | {:error, term()}
  def compare(run_a, run_b) do
    with {:ok, a} <- Egghead.get_record(normalize_run_id(run_a)),
         {:ok, b} <- Egghead.get_record(normalize_run_id(run_b)) do
      id =
        "eval-compare/#{a.id |> String.replace("/", "-")}-vs-#{b.id |> String.replace("/", "-")}"

      attrs = %{
        "id" => id,
        "title" => "Eval comparison: #{a.id} vs #{b.id}",
        "class" => "durable",
        "tags" => ["eval", "comparison"],
        "links" => [a.id, b.id],
        "body" => compare_body(a, b)
      }

      Egghead.create_record(attrs)
    end
  end

  defp compare_body(a, b) do
    """
    # Comparison — #{a.id} vs #{b.id}

    | Metric | #{a.id} | #{b.id} |
    |---|---|---|
    | KPI | #{get_meta(a, "kpi")} | #{get_meta(b, "kpi")} |
    | Communication | #{get_meta(a, "communication")} | #{get_meta(b, "communication")} |
    | Planning | #{get_meta(a, "planning")} | #{get_meta(b, "planning")} |
    | Roster mode | #{get_meta(a, "roster_mode")} | #{get_meta(b, "roster_mode")} |
    | Turns | #{get_meta(a, "turns")} | #{get_meta(b, "turns")} |
    | Duration (ms) | #{get_meta(a, "duration_ms")} | #{get_meta(b, "duration_ms")} |
    | Judge | #{get_meta(a, "judge_model")} | #{get_meta(b, "judge_model")} |

    ## #{a.id}

    [[#{a.id}]]

    ## #{b.id}

    [[#{b.id}]]
    """
  end

  defp get_meta(%{meta: meta}, key), do: Map.get(meta || %{}, key, "—")

  defp normalize_run_id(id) do
    if String.starts_with?(id, "eval-runs/"), do: id, else: "eval-runs/#{id}"
  end

  # Re-export the Reporter for callers that want to render a score
  # without persisting a record (e.g. CLI live output).
  @doc false
  defdelegate render_body(opts), to: Reporter, as: :body
end
