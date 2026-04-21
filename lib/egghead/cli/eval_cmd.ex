defmodule Egghead.CLI.EvalCmd do
  @moduledoc """
  `egghead eval` — run multi-agent evaluation tasks.

  Posts a task prompt to an ephemeral chat room, waits for convergence,
  grades the transcript with a synthetic Judge agent, and writes a
  durable run record. Inspired by MultiAgentBench (Zhu et al., ACL 2025).
  See `records/design/eval.md` in the record store for the full design.
  """

  alias Egghead.CLI.Widgets

  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        switches: [
          help: :boolean,
          roster: :string,
          judge: :string,
          timeout: :integer,
          round_budget: :integer
        ],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        print_help()

      positional == [] ->
        do_list_tasks()

      true ->
        case positional do
          ["list" | _] -> do_list_tasks()
          ["runs" | _] -> do_list_runs()
          ["run", task_id | _] -> do_run(task_id, opts)
          ["run" | _] -> usage_error("run requires a task id")
          ["report", run_id | _] -> do_report(run_id)
          ["report" | _] -> usage_error("report requires a run id")
          ["compare", a, b | _] -> do_compare(a, b)
          ["compare" | _] -> usage_error("compare requires two run ids")
          [other | _] -> usage_error("unknown subcommand: #{other}")
        end
    end
  end

  # ---- subcommands -------------------------------------------------------

  defp do_list_tasks do
    Egghead.CLI.prepare_runtime()

    tasks = Egghead.Eval.list_tasks()

    if tasks == [] do
      IO.puts("No bundled tasks found.")
    else
      Widgets.header("Available eval tasks")

      tasks
      |> Enum.group_by(& &1.category)
      |> Enum.sort()
      |> Enum.each(fn {category, group} ->
        IO.puts("\n  \e[1m#{category}\e[0m")

        # Leave room for the 6-space indent; wrap the rest.
        blurb_width = max(40, term_cols() - 6)

        Enum.each(group, fn t ->
          caps =
            if t.required_capabilities == [],
              do: "",
              else: " " <> Widgets.dim("(#{Enum.join(t.required_capabilities, ", ")})")

          blurb = t.description || t.title || first_sentence(t.prompt)

          IO.puts("    \e[1m#{t.id}\e[0m#{caps}")

          blurb
          |> wrap_text(blurb_width)
          |> Enum.each(fn line -> IO.puts("      " <> Widgets.dim(line)) end)
        end)
      end)

      IO.puts("")
      IO.puts("  #{length(tasks)} task(s). Run one with: egghead eval run <id>")
    end
  end

  defp do_list_runs do
    Egghead.CLI.prepare_runtime()

    runs = Egghead.Eval.list_runs()

    if runs == [] do
      IO.puts("No eval runs yet. Run one with: egghead eval run <task-id>")
    else
      Widgets.header("Eval runs")

      runs
      |> Enum.sort_by(& &1.created, :desc)
      |> Enum.each(fn r ->
        meta = r.meta || %{}
        kpi = format_kpi(meta["kpi"])
        cat = meta["category"] || "?"
        task = meta["task"] || "?"
        IO.puts("  #{r.id}  #{Widgets.dim("[#{cat}]")}  KPI=#{kpi}  task=#{task}")
      end)

      IO.puts("")
      IO.puts("  #{length(runs)} run(s).")
    end
  end

  defp do_run(task_id, opts) do
    Egghead.CLI.prepare_runtime()

    run_opts =
      []
      |> put_if(opts[:roster], :roster, parse_roster_mode(opts[:roster]))
      |> put_if(opts[:judge], :judge_model, opts[:judge])
      |> put_if(opts[:timeout], :timeout, opts[:timeout])
      |> put_if(opts[:round_budget], :round_budget, opts[:round_budget])
      |> Keyword.put(:on_event, &live_event/1)

    IO.puts("")
    Widgets.header("Eval run · #{task_id}")

    try do
      case Egghead.Eval.run(task_id, run_opts) do
        {:ok, %{status: :ok} = result} ->
          IO.puts("")
          IO.puts(render_summary(result))

        {:ok, %{status: :skipped, reason: reason}} ->
          IO.puts("")
          IO.puts("\e[33mSKIPPED:\e[0m #{inspect(reason)}")

        {:ok, %{status: :error, reason: reason}} ->
          IO.puts("")
          IO.puts("\e[31mERROR:\e[0m #{inspect(reason)}")
          System.halt(1)

        {:error, reason} ->
          IO.puts("")
          IO.puts("\e[31mERROR:\e[0m #{inspect(reason)}")
          System.halt(1)
      end
    after
      Widgets.spinner_stop()
    end
  end

  defp do_report(run_id) do
    Egghead.CLI.prepare_runtime()

    case Egghead.Eval.report(run_id) do
      {:ok, body} ->
        IO.puts(body)

      {:error, reason} ->
        IO.puts("Report failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp do_compare(a, b) do
    Egghead.CLI.prepare_runtime()

    case Egghead.Eval.compare(a, b) do
      {:ok, record} ->
        IO.puts("Comparison written: #{record.id}")
        IO.puts("")
        IO.puts(record.body)

      {:error, reason} ->
        IO.puts("Compare failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # ---- live event printer ------------------------------------------------
  #
  # We keep a single spinner pid in the process dictionary and swap it on
  # every event. The CLI is a short-lived process (per-invocation), so
  # using the pdict as a mailbox for the spinner is fine — no concurrency,
  # no cleanup needed beyond the final stop.

  defp live_event({:started, %{run_id: run_id, mode: mode}}) do
    IO.puts("  run-id: #{run_id}")
    IO.puts("  roster: #{mode}")
    Widgets.spinner_start("resolving roster…")
  end

  defp live_event({:spawning_personas, ids}) do
    Widgets.spinner_stop()
    IO.puts("  spawning #{length(ids)} persona(s): #{Enum.join(ids, ", ")}")
    Widgets.spinner_start("preparing room…")
  end

  defp live_event({:room_opened, %{room_id: room_id, roster: roster}}) do
    Widgets.spinner_stop()
    IO.puts("  room:   #{room_id}")

    if roster == [] do
      IO.puts("  agents: " <> "\e[31m(none joined)\e[0m")
    else
      IO.puts("  agents: #{Enum.join(roster, ", ")}")
    end

    IO.puts("")
    Widgets.spinner_start("waiting for agents to engage…")
  end

  defp live_event({:empty_roster, %{requested: ids}}) do
    Widgets.spinner_stop()
    Widgets.error("Room opened with zero joined agents.")

    IO.puts(
      "  " <>
        Widgets.dim(
          "Requested: #{Enum.join(ids, ", ")}. " <>
            "Likely means the persona processes aren't registered under their agent_name/1."
        )
    )

    Widgets.spinner_start("waiting for idle timeout…")
  end

  defp live_event({:turn, msg}) do
    Widgets.spinner_stop()

    name =
      case msg.sender do
        %{name: name, type: :agent} -> name
        %{name: name} -> name
        _ -> "?"
      end

    preview =
      msg.content
      |> String.trim()
      |> String.split("\n")
      |> List.first()
      |> truncate(78)

    IO.puts("  \e[36m#{name}\e[0m  #{preview}")
    Widgets.spinner_start("waiting for next turn…")
  end

  defp live_event({:pass, agent_id}) do
    Widgets.spinner_stop()
    IO.puts("  " <> Widgets.dim("#{agent_id} /pass"))
    Widgets.spinner_start("waiting for next turn…")
  end

  defp live_event({:judging, _}) do
    Widgets.spinner_stop()
    IO.puts("")
    Widgets.spinner_start("judging transcript…")
  end

  defp live_event({:scored, _}) do
    # Swap to a quieter "writing…" label; the summary block below
    # will show the actual scores. No need to announce "scored." here.
    Widgets.spinner_stop()
    Widgets.spinner_start("writing run record…")
  end

  defp live_event({:persisted, _id}) do
    # The summary block below includes the record id; no need to
    # announce it twice.
    Widgets.spinner_stop()
  end

  defp live_event({:capability_gate, {{:missing, missing}, _roster}}) do
    Widgets.spinner_stop()
    IO.puts("  \e[33mCapability gate:\e[0m missing #{Enum.join(missing, ", ")}")
  end

  defp live_event({:skipped, reason}) do
    Widgets.spinner_stop()
    IO.puts("  \e[33mSkipped:\e[0m #{inspect(reason)}")
  end

  defp live_event({:error, reason}) do
    Widgets.spinner_stop()
    IO.puts("  \e[31mError:\e[0m #{inspect(reason)}")
  end

  defp live_event(_), do: :ok

  # ---- helpers -----------------------------------------------------------

  # High-level summary printed after a successful run. Mirrors the
  # *data* in the persisted record — KPI, dimension scores, roster,
  # token usage — but keeps the detail (per-milestone table, judge
  # rationale, footnotes) in the record itself. One glance here,
  # deep-dive in the record.
  defp render_summary(%{score: score} = result) when not is_nil(score) do
    record_id = Map.get(result, :record_id) || "(not persisted)"
    tokens = Map.get(result, :tokens) || %{}
    roster = Map.get(result, :roster) || []
    kpi = format_kpi(score.kpi)
    comm = score.communication || "—"
    plan = score.planning || "—"

    task_specific_line =
      score.task_specific
      |> Enum.filter(fn {_, v} -> is_number(v) end)
      |> Enum.map(fn {k, v} -> "#{humanize(k)} #{v}/5" end)
      |> case do
        [] -> nil
        list -> "  Task-specific:  " <> Enum.join(list, " · ")
      end

    contribution_lines =
      score.per_agent
      |> Enum.sort_by(fn {_, %{fraction: f}} -> -f end)
      |> Enum.map(fn {id, %{achieved: a, total: t, fraction: f}} ->
        tokens_str = agent_token_str(id, tokens)

        "    #{String.pad_trailing(id, 20)} #{bar(f, 10)}  " <>
          "#{a}/#{t} milestones#{tokens_str}"
      end)

    contribution_block =
      case contribution_lines do
        [] -> nil
        lines -> "  \e[1mPer-agent:\e[0m\n" <> Enum.join(lines, "\n")
      end

    token_total = token_total_str(tokens)

    [
      "\e[1mResult\e[0m",
      "  KPI:            #{kpi}",
      "  Communication:  #{comm}/5",
      "  Planning:       #{plan}/5",
      task_specific_line,
      "  Roster:         #{Enum.join(roster, ", ")}",
      token_total,
      "  Record:         #{record_id}",
      contribution_block
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp render_summary(%{record_id: nil}), do: "(no record)"
  defp render_summary(_), do: "(no summary)"

  defp agent_token_str(id, %{per_agent: per_agent}) when is_map(per_agent) do
    case Map.get(per_agent, id) do
      %{input: i, output: o} when i + o > 0 ->
        "  " <> Widgets.dim("#{format_tokens(i + o)} tok")

      _ ->
        ""
    end
  end

  defp agent_token_str(_, _), do: ""

  defp token_total_str(%{total: %{input: i, output: o}}) when i + o > 0 do
    "  Tokens:         " <>
      Widgets.dim("#{format_tokens(i)} in · #{format_tokens(o)} out · #{format_tokens(i + o)} total")
  end

  defp token_total_str(_), do: nil

  defp format_tokens(n) when is_integer(n) and n >= 1000 do
    :erlang.float_to_binary(n / 1000.0, decimals: 1) <> "K"
  end

  defp format_tokens(n) when is_integer(n), do: Integer.to_string(n)
  defp format_tokens(_), do: "0"

  defp bar(fraction, width) do
    filled = max(0, min(width, round(fraction * width)))
    "\e[36m" <>
      String.duplicate("█", filled) <>
      "\e[38;5;245m" <>
      String.duplicate("░", width - filled) <>
      "\e[0m"
  end

  defp humanize(atom) when is_atom(atom), do: humanize(Atom.to_string(atom))
  defp humanize(s) when is_binary(s), do: s |> String.replace("_", " ") |> String.capitalize()

  defp format_kpi(nil), do: "—"
  defp format_kpi(k) when is_number(k), do: :erlang.float_to_binary(k * 1.0, decimals: 2)

  defp parse_roster_mode("user"), do: :user
  defp parse_roster_mode("task"), do: :task
  defp parse_roster_mode(_), do: :user

  defp put_if(kw, nil, _, _), do: kw
  defp put_if(kw, _, key, val), do: Keyword.put(kw, key, val)

  defp truncate(s, n) when is_binary(s) do
    if String.length(s) > n, do: String.slice(s, 0, n - 1) <> "…", else: s
  end

  defp truncate(_, _), do: ""

  # Fallback blurb: first sentence of the prompt, headers stripped.
  defp first_sentence(prompt) when is_binary(prompt) do
    prompt
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> List.first()
    |> case do
      nil -> ""
      line -> line |> String.split(~r/(?<=[.!?])\s+/, parts: 2) |> List.first()
    end
  end

  defp first_sentence(_), do: ""

  defp term_cols do
    case :io.columns() do
      {:ok, cols} when is_integer(cols) and cols > 0 -> cols
      _ -> 100
    end
  end

  # Greedy word-wrap. Preserves words; breaks only at whitespace.
  # Empty input returns a single empty line so the caller always
  # draws at least one row.
  defp wrap_text(text, width) when is_binary(text) and is_integer(width) and width > 0 do
    words = text |> String.trim() |> String.split(~r/\s+/)

    {lines, last} =
      Enum.reduce(words, {[], ""}, fn word, {acc, current} ->
        cond do
          current == "" ->
            {acc, word}

          String.length(current) + 1 + String.length(word) <= width ->
            {acc, current <> " " <> word}

          true ->
            {[current | acc], word}
        end
      end)

    (Enum.reverse([last | lines]) |> Enum.reject(&(&1 == "")))
    |> case do
      [] -> [""]
      list -> list
    end
  end

  defp wrap_text(_, _), do: [""]

  defp usage_error(msg) do
    IO.puts(:stderr, "egghead eval: #{msg}")
    IO.puts(:stderr, "Run 'egghead eval --help' for usage.")
    System.halt(1)
  end

  defp print_help do
    IO.puts("""
    USAGE
      egghead eval [command] [flags]

    DESCRIPTION
      Run multi-agent evaluation tasks against the agents defined in your
      record store. Inspired by MultiAgentBench (MARBLE, Zhu et al., ACL 2025),
      eval posts a task prompt to an ephemeral chat room, waits for the agents
      to converge, then grades the transcript with a synthetic Judge agent.

      Each run produces a durable markdown record in your store with three
      scores ported from MARBLE — KPI (milestone attribution), Communication,
      and Planning — plus task-specific scores where applicable.

      Two roster modes:
        --roster user   use your own class:agent records (the default)
        --roster task   use the personas shipped with the task, for
                        MARBLE-comparable benchmark runs

      The Judge is a built-in synthetic agent (like Index). Drop a
      class:agent record with id "judge" in your store to override its
      disposition, or use --judge to override just the model.

    COMMANDS
      list                   List bundled eval tasks (default)
      runs                   List past eval runs from the record store
      run <task-id>          Run a task, judge it, and persist the run record
      report <run-id>        Print the body of an existing run record
      compare <a> <b>        Produce a side-by-side comparison record

    FLAGS FOR `run`
      --roster user|task     Use user's class:agent records, or the task's
                             bundled personas (default: user)
      --judge PROVIDER/MODEL Override Judge's model for this call
      --timeout MS           Max wait for agent convergence (default: 300000)
      --round-budget N       Max agent turn-rounds (default: 10)

    EXAMPLES
      $ egghead eval list
      $ egghead eval run research/profile-1 --roster task
      $ egghead eval run research/profile-1 --judge anthropic/claude-sonnet-4-6
      $ egghead eval runs
      $ egghead eval report 2026-04-20-a3f2
      $ egghead eval compare 2026-04-20-a3f2 2026-04-20-b7c1

    SEE ALSO
      records/design/eval.md (in your records store) — full design
    """)
  end
end
