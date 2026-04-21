defmodule Egghead.Eval.Scorer do
  @moduledoc """
  Post-hoc judging: take a run's transcript and milestones, prompt the
  Judge agent for the three core MARBLE scores (KPI / Communication /
  Planning), plus any task-specific scores (research, bargaining).

  The Judge is invoked via the normal agent prompt path
  (`Egghead.Agent.prompt/3`) so a user's shadow Judge record is
  automatically used if present. An explicit `:judge_model` override
  bypasses the configured model for this call only, useful for CLI
  `--judge provider/model`.

  Returns a `%Score{}` — a plain-data struct suitable for serialization
  into the run record's frontmatter and rendering in the report body.
  """

  alias Egghead.Eval.{Judge, Prompts, Task}

  defmodule Score do
    @moduledoc false

    defstruct kpi: 0.0,
              communication: nil,
              planning: nil,
              task_specific: %{},
              milestones: [],
              per_agent: %{},
              raw: %{}
  end

  @type transcript_msg :: %{
          required(:sender) => %{type: atom(), name: String.t(), id: String.t() | nil},
          required(:content) => String.t(),
          required(:timestamp) => DateTime.t()
        }

  @doc """
  Grades a transcript against a task. Returns `{:ok, %Score{}}` or
  `{:error, reason}`.

  ## Options

    * `:judge_model` — override the Judge's configured model for this
      call (e.g. `"anthropic/claude-sonnet-4-6"`). The Judge agent is
      still the one sending the prompts; only its model is swapped.
    * `:roster` — the list of agent ids that were present in the room.
      Used to compute KPI as `Σ nⱼ / (N · M)`.
  """
  @spec grade(Task.t(), [transcript_msg()], keyword()) ::
          {:ok, Score.t()} | {:error, term()}
  def grade(%Task{} = task, transcript, opts \\ []) when is_list(transcript) do
    roster = Keyword.get(opts, :roster, [])
    judge_model = Keyword.get(opts, :judge_model)

    # Tests pass `:judge_fun` to bypass the real agent entirely. In
    # production this stays nil and we hit the Judge agent via
    # Egghead.Agent.prompt/3.
    judge_fun =
      Keyword.get(opts, :judge_fun, fn prompt ->
        default_judge_call(prompt, judge_model)
      end)

    transcript_text = format_for_judge(transcript)
    task_text = task.prompt

    with {:ok, milestones_raw, milestones} <-
           ask_milestones(task_text, transcript_text, task.milestones, judge_fun),
         {:ok, comm_raw, comm} <- ask_communication(task_text, transcript_text, judge_fun),
         {:ok, plan_raw, plan} <-
           ask_planning(task, transcript, transcript_text, judge_fun),
         {:ok, task_raw, task_specific} <-
           ask_task_specific(task, transcript_text, judge_fun) do
      per_agent = per_agent_contributions(milestones, roster)
      kpi = kpi_overall(milestones, roster)

      score = %Score{
        kpi: kpi,
        communication: comm,
        planning: plan,
        task_specific: task_specific,
        milestones: milestones,
        per_agent: per_agent,
        raw: %{
          milestones: milestones_raw,
          communication: comm_raw,
          planning: plan_raw,
          task_specific: task_raw
        }
      }

      {:ok, score}
    end
  end

  # ---- KPI formula --------------------------------------------------------
  #
  #   KPI_overall = (1 / (N · M)) · Σⱼ nⱼ
  #
  # where N = agent count, M = total milestones, nⱼ = milestones that
  # agent j contributed to. Source: MARBLE paper §4.

  defp kpi_overall(_milestones, []), do: 0.0
  defp kpi_overall([], _roster), do: 0.0

  defp kpi_overall(milestones, roster) do
    n = length(roster)
    m = length(milestones)

    total =
      roster
      |> Enum.map(fn agent_id ->
        Enum.count(milestones, fn %{"agents" => agents} ->
          agent_id in List.wrap(agents)
        end)
      end)
      |> Enum.sum()

    total / (n * m)
  end

  defp per_agent_contributions(milestones, roster) do
    total = length(milestones)

    Map.new(roster, fn agent_id ->
      achieved =
        Enum.count(milestones, fn %{"agents" => agents} ->
          agent_id in List.wrap(agents)
        end)

      fraction = if total == 0, do: 0.0, else: achieved / total
      {agent_id, %{achieved: achieved, total: total, fraction: fraction}}
    end)
  end

  # ---- Judge prompt calls -------------------------------------------------

  defp ask_milestones(task, transcript, candidate_milestones, judge_fun) do
    prompt = Prompts.kpi(task, transcript, candidate_milestones)

    with {:ok, text} <- judge_fun.(prompt),
         {:ok, json} <- decode_json(text),
         :ok <- validate_milestones(json) do
      {:ok, text, json}
    end
  end

  defp ask_communication(task, transcript, judge_fun) do
    prompt = Prompts.communication(task, transcript)

    with {:ok, text} <- judge_fun.(prompt),
         {:ok, %{"rating" => rating}} <- decode_json(text) do
      {:ok, text, clamp_rating(rating)}
    else
      _ -> {:ok, "unparsed", nil}
    end
  end

  defp ask_planning(task, transcript_msgs, transcript_text, judge_fun) do
    summary = short_summary(transcript_msgs)

    agent_profiles =
      transcript_msgs
      |> Enum.filter(&(&1.sender.type == :agent))
      |> Enum.map(& &1.sender.id)
      |> Enum.uniq()
      |> Enum.join(", ")

    prompt = Prompts.planning(summary, agent_profiles, task.prompt, transcript_text)

    with {:ok, text} <- judge_fun.(prompt),
         {:ok, %{"rating" => rating}} <- decode_json(text) do
      {:ok, text, clamp_rating(rating)}
    else
      _ -> {:ok, "unparsed", nil}
    end
  end

  defp ask_task_specific(%Task{category: :research} = task, transcript_text, judge_fun) do
    prompt = Prompts.research(task.prompt, transcript_text)

    with {:ok, text} <- judge_fun.(prompt),
         {:ok, parsed} <- decode_json(text) do
      keys = ["innovation", "safety", "feasibility"]
      scores = Map.new(keys, fn k -> {k, clamp_rating(Map.get(parsed, k))} end)
      {:ok, text, scores}
    else
      _ -> {:ok, "unparsed", %{}}
    end
  end

  defp ask_task_specific(%Task{category: :bargaining} = task, transcript_text, judge_fun) do
    seller =
      judge_fun.(Prompts.bargaining_seller(task.prompt, transcript_text))
      |> parse_bargaining_side("seller")

    buyer =
      judge_fun.(Prompts.bargaining_buyer(task.prompt, transcript_text))
      |> parse_bargaining_side("buyer")

    {:ok, "parsed", Map.merge(seller, buyer)}
  end

  defp ask_task_specific(_task, _transcript, _judge), do: {:ok, nil, %{}}

  defp parse_bargaining_side({:ok, text}, key) do
    case decode_json(text) do
      {:ok, %{^key => side}} when is_map(side) -> %{key => side}
      _ -> %{}
    end
  end

  defp parse_bargaining_side(_, _), do: %{}

  # ---- Judge agent invocation --------------------------------------------

  defp default_judge_call(prompt, judge_model) do
    judge_id = Judge.id()

    with :ok <- ensure_judge_running(judge_model),
         {:ok, response} <- Egghead.Agent.prompt(judge_id, prompt, []) do
      {:ok, extract_text(response)}
    end
  end

  # Make sure a Judge agent is running before we try to prompt it.
  # Users connected to a long-running egghead server may be talking
  # to a pre-upgrade process that never spawned the synthetic Judge,
  # so checking presence and starting on demand is safer than relying
  # on sync_agents alone. A `:judge_model` override always restarts
  # the synthetic Judge with that model (user-shadowed judges are
  # left untouched — the override is advisory for them).
  defp ensure_judge_running(model_override) do
    if Egghead.Eval.Judge.user_shadow?() do
      :ok
    else
      judge_name = Egghead.Agent.agent_name(Judge.id())

      cond do
        model_override != nil ->
          start_synthetic_judge(model: model_override)

        GenServer.whereis(judge_name) == nil ->
          start_synthetic_judge([])

        true ->
          :ok
      end
    end
  end

  defp start_synthetic_judge(opts) do
    record = Egghead.Eval.Judge.default_agent(opts)
    _ = Egghead.Agent.Supervisor.start_agent(Egghead.Agent.Supervisor, record)
    :ok
  end

  defp extract_text(%{content: text}) when is_binary(text), do: text
  defp extract_text(%{text: text}) when is_binary(text), do: text
  defp extract_text(text) when is_binary(text), do: text
  defp extract_text(other), do: inspect(other)

  # ---- JSON & validation --------------------------------------------------

  defp decode_json(text) when is_binary(text) do
    # Judge output sometimes arrives with stray whitespace or a
    # code-fenced block; strip before decoding.
    cleaned =
      text
      |> String.trim()
      |> String.replace(~r/\A```(?:json)?\s*/, "")
      |> String.replace(~r/\s*```\z/, "")

    case Jason.decode(cleaned) do
      {:ok, value} -> {:ok, value}
      {:error, _} = err -> err
    end
  end

  defp decode_json(other), do: {:error, {:not_a_string, other}}

  defp validate_milestones(list) when is_list(list) do
    if Enum.all?(list, fn
         %{"milestone" => m, "agents" => a} when is_binary(m) and is_list(a) -> true
         _ -> false
       end),
       do: :ok,
       else: {:error, :invalid_milestone_shape}
  end

  defp validate_milestones(_), do: {:error, :not_a_list}

  defp clamp_rating(n) when is_number(n), do: min(5, max(1, round(n)))
  defp clamp_rating(_), do: nil

  defp format_for_judge(transcript) do
    Egghead.Chat.Room.format_transcript(transcript)
  end

  defp short_summary(transcript) do
    n = length(transcript)
    "Multi-agent transcript, #{n} messages."
  end
end
