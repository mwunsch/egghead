defmodule Egghead.Eval.Reporter do
  @moduledoc """
  Renders eval run records — markdown with task-list milestones,
  ASCII per-agent contribution bars, multi-dimensional scores, and
  a link back to the transcript.

  Produces a full `create_record` attribute map including frontmatter
  meta for query, or just the body for inline display (e.g. the CLI's
  live final-report block).
  """

  alias Egghead.Eval.{Scorer, Task}

  @type run_opts :: %{
          required(:run_id) => String.t(),
          required(:task) => Task.t(),
          required(:score) => Scorer.Score.t(),
          required(:roster) => [String.t()],
          required(:transcript_id) => String.t() | nil,
          required(:duration_ms) => non_neg_integer(),
          required(:turns) => non_neg_integer(),
          required(:roster_mode) => :user | :task,
          required(:judge_model) => String.t() | nil,
          optional(:tokens) => %{
            per_agent: %{String.t() => %{input: non_neg_integer(), output: non_neg_integer()}},
            total: %{input: non_neg_integer(), output: non_neg_integer()}
          }
        }

  @doc """
  Returns a map ready to pass to `Egghead.create_record/1`.
  """
  @spec to_record_attrs(run_opts()) :: map()
  def to_record_attrs(opts) do
    %{
      "id" => "eval-runs/#{opts.run_id}",
      "title" => title(opts),
      "class" => "durable",
      "tags" => tags(opts),
      "author" => "judge",
      "links" => links(opts),
      "meta" => frontmatter_meta(opts),
      "body" => body(opts)
    }
  end

  @doc """
  Returns the markdown body only — suitable for live CLI output.
  """
  @spec body(run_opts()) :: String.t()
  def body(opts) do
    [
      header(opts),
      "",
      score_summary(opts.score),
      "",
      run_stats(opts),
      "",
      "## Milestones",
      "",
      milestones_list(opts.score.milestones),
      "",
      "## Per-agent contribution",
      "",
      contribution_block(opts.score.per_agent, opts[:tokens]),
      "",
      "## Judge's rationale",
      "",
      rationale(opts.score),
      "",
      transcript_pointer(opts.transcript_id)
    ]
    |> Enum.reject(&(&1 == nil))
    |> Enum.join("\n")
  end

  defp run_stats(opts) do
    duration_s = div(opts.duration_ms, 1000)
    judge = opts.judge_model || "(default)"
    roster = Enum.join(opts.roster, ", ")

    token_line =
      case opts[:tokens] do
        %{total: %{input: i, output: o}} when i + o > 0 ->
          " · Tokens: #{format_int(i)} in / #{format_int(o)} out"

        _ ->
          ""
      end

    "**Roster:** #{roster}  \n" <>
      "**Run:** #{opts.turns} turns · #{duration_s}s · judge #{judge}#{token_line}"
  end

  defp format_int(n) when is_integer(n) and n >= 1000,
    do: :erlang.float_to_binary(n / 1000.0, decimals: 1) <> "K"

  defp format_int(n), do: Integer.to_string(n)

  # ---- sections -----------------------------------------------------------

  defp header(opts) do
    "# #{title(opts)}"
  end

  defp title(%{task: task, run_id: run_id}) do
    cat = task.category |> to_string() |> String.capitalize()
    "#{cat} · #{task.id} · #{run_id}"
  end

  defp score_summary(score) do
    base =
      [
        {"KPI", format_kpi(score.kpi)},
        {"Communication", format_rating(score.communication)},
        {"Planning", format_rating(score.planning)}
      ]
      |> Enum.map(fn {label, val} -> "**#{label}:** #{val}" end)

    task_specific =
      score.task_specific
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Enum.map(fn
        {k, v} when is_number(v) ->
          "**#{humanize(k)}:** #{format_rating(v)}"

        {k, v} when is_map(v) ->
          "**#{humanize(k)}:** #{inspect(v)}"
      end)

    (base ++ task_specific) |> Enum.join(" · ")
  end

  defp format_kpi(k) when is_number(k), do: :erlang.float_to_binary(k * 1.0, decimals: 2)
  defp format_kpi(_), do: "—"

  defp format_rating(nil), do: "—"
  defp format_rating(n) when is_number(n), do: "#{n}/5"

  defp milestones_list([]), do: "_No milestones achieved._"

  defp milestones_list(milestones) do
    milestones
    |> Enum.with_index(1)
    |> Enum.map(fn {%{"milestone" => m, "agents" => agents}, i} ->
      achieved = agents != []
      box = if achieved, do: "[x]", else: "[ ]"

      attribution =
        case agents do
          [] -> ""
          list -> " — _#{Enum.join(list, ", ")}_ [^m#{i}]"
        end

      "- #{box} #{m}#{attribution}"
    end)
    |> Enum.join("\n")
  end

  defp contribution_block(per_agent, _tokens) when map_size(per_agent) == 0 do
    "```\n(no agents)\n```"
  end

  defp contribution_block(per_agent, tokens) do
    width = per_agent |> Map.keys() |> Enum.map(&String.length/1) |> Enum.max(fn -> 14 end)
    per_agent_tokens = tokens_per_agent(tokens)

    rows =
      per_agent
      |> Enum.sort_by(fn {_, %{fraction: f}} -> -f end)
      |> Enum.map(fn {id, %{achieved: a, total: t, fraction: f}} ->
        bar = bar(f, 10)
        pct = :erlang.float_to_binary(f * 1.0, decimals: 2)
        tok = Map.get(per_agent_tokens, id, "")

        String.pad_trailing(id, width) <>
          " " <> bar <> "  #{pct} (#{a} of #{t})" <> tok
      end)

    "```\n" <> Enum.join(rows, "\n") <> "\n```"
  end

  defp tokens_per_agent(%{per_agent: pa}) when is_map(pa) do
    Map.new(pa, fn {id, %{input: i, output: o}} ->
      total = i + o

      suffix =
        if total > 0,
          do: "  #{format_int(total)} tok",
          else: ""

      {id, suffix}
    end)
  end

  defp tokens_per_agent(_), do: %{}

  defp bar(fraction, width) do
    filled = max(0, min(width, round(fraction * width)))
    String.duplicate("█", filled) <> String.duplicate("░", width - filled)
  end

  defp rationale(score) do
    # Footnote bodies come from the milestone list itself (evidence
    # attribution). The rationale prose is short — the milestones
    # themselves carry most of the "why."
    if score.milestones == [] do
      "_The judge identified no concrete milestones in this transcript._"
    else
      achieved = Enum.count(score.milestones, &(&1["agents"] != []))
      total = length(score.milestones)

      "Identified #{total} candidate milestones; #{achieved} achieved. " <>
        "Per-agent contributions above show load distribution across the roster."
    end <> "\n\n" <> footnotes(score.milestones)
  end

  defp footnotes(milestones) do
    milestones
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {%{"milestone" => m, "agents" => agents}, i} ->
      if agents == [],
        do: [],
        else: ["[^m#{i}]: Achieved by #{Enum.join(agents, ", ")}: #{m}"]
    end)
    |> Enum.join("\n")
  end

  defp transcript_pointer(nil), do: ""
  defp transcript_pointer(id), do: "## Transcript\n\n[[#{id}]]"

  # ---- frontmatter --------------------------------------------------------

  defp frontmatter_meta(opts) do
    base = %{
      "kpi" => opts.score.kpi,
      "communication" => opts.score.communication,
      "planning" => opts.score.planning,
      "roster_mode" => to_string(opts.roster_mode),
      "roster" => opts.roster,
      "task" => opts.task.id,
      "category" => to_string(opts.task.category),
      "duration_ms" => opts.duration_ms,
      "turns" => opts.turns,
      "judge_model" => opts.judge_model
    }

    with_tokens =
      case opts[:tokens] do
        %{total: %{input: i, output: o}} ->
          Map.merge(base, %{
            "tokens_in" => i,
            "tokens_out" => o,
            "tokens_total" => i + o
          })

        _ ->
          base
      end

    Map.merge(with_tokens, stringify_task_specific(opts.score.task_specific))
  end

  defp stringify_task_specific(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp tags(%{task: task}) do
    ["eval", "run", to_string(task.category)]
  end

  defp links(opts) do
    base = ["eval-task:" <> opts.task.id]

    # Room.save_transcript already persists the record with id
    # "chat/<room-id>" — link to that verbatim, no re-prefixing.
    case opts.transcript_id do
      nil -> base
      id -> base ++ [id]
    end
    |> Enum.uniq()
  end

  defp humanize(atom) when is_atom(atom), do: humanize(Atom.to_string(atom))
  defp humanize(s) when is_binary(s), do: s |> String.replace("_", " ") |> String.capitalize()
end
