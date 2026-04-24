defmodule Egghead.Eval.Runner do
  @moduledoc """
  Orchestrates a single eval run.

  1. Resolve the roster (`:user` uses the store's `class: agent`
     records; `:task` uses the personas shipped alongside the task).
  2. Capability-union check — skip with a clear message if required
     verbs aren't covered.
  3. Create an ephemeral chat room joined to only that roster.
  4. Post the task prompt, subscribe to room events, and collect
     turns until agents converge or the timeout is hit.
  5. Save the transcript as a `class: transcript` record.
  6. Stop the room; terminate any transient personas.
  7. Invoke `Egghead.Eval.Scorer.grade/3` with the transcript.
  8. Render and persist the durable run record.

  Serial; one run at a time. Transient personas are spawned directly
  into the running `Agent.Supervisor` and not persisted to the user's
  store — they vanish when the run completes.
  """

  require Logger

  alias Egghead.Chat.Room
  alias Egghead.Eval.{CapabilityCheck, Judge, Persona, Reporter, Scorer, Task}

  @type roster_mode :: :user | :task

  @type result :: %{
          run_id: String.t(),
          task_id: String.t(),
          record_id: String.t() | nil,
          transcript_id: String.t() | nil,
          score: Scorer.Score.t() | nil,
          roster: [String.t()],
          tokens: map() | nil,
          turns: non_neg_integer(),
          duration_ms: non_neg_integer(),
          status: :ok | :skipped | :error,
          reason: term() | nil
        }

  @doc """
  Runs a single task.

  ## Options

    * `:roster` — `:user` (default) or `:task`
    * `:timeout` — ms, default 300_000
    * `:judge_model` — override model for Judge (e.g. `"anthropic/claude-sonnet-4-6"`)
    * `:on_event` — a zero/one-arg callback invoked with `{:phase, ...}`
      tuples as the run progresses. Used by the CLI for live output.
  """
  @spec run(String.t() | Task.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(task_or_id, opts \\ [])

  def run(task_id, opts) when is_binary(task_id) do
    with {:ok, task} <- Task.fetch(task_id) do
      run(task, opts)
    end
  end

  def run(%Task{} = task, opts) do
    on_event = Keyword.get(opts, :on_event, fn _ -> :ok end)
    mode = Keyword.get(opts, :roster, :user)
    run_id = mint_run_id()

    emit(on_event, {:started, %{run_id: run_id, task: task, mode: mode}})

    with {:ok, transient_ids, roster} <- resolve_roster(task, mode, on_event),
         :ok <- gate_capabilities(task, roster, on_event),
         {:ok, run_state} <-
           execute(task, roster, Keyword.put(opts, :run_id, run_id), on_event) do
      cleanup_transients(transient_ids)
      outcome = finalize(task, run_state, roster, mode, opts, on_event)
      {:ok, outcome}
    else
      {:skipped, reason} ->
        emit(on_event, {:skipped, reason})

        {:ok,
         %{
           run_id: run_id,
           task_id: task.id,
           record_id: nil,
           transcript_id: nil,
           score: nil,
           status: :skipped,
           reason: reason
         }}

      {:error, reason} = err ->
        emit(on_event, {:error, reason})
        err
    end
  end

  # MARBLE's engine drives iterations by re-invoking every agent
  # per round against the accumulated shared memory (no explicit
  # prompt — the agent.plan_task()/agent.act() cycle happens
  # programmatically). Our equivalent is a user_message that
  # triggers the Coordinator's activate path over the room's
  # joined roster. The nudge is deliberately minimal — the real
  # context is the transcript the agent already sees.
  defp round_prompt(round_n, total) do
    """
    [Iteration #{round_n} of #{total}]

    Continue working on the task. Review what's been done so far in
    this conversation (including any files written to the workspace
    or records created) and take your next action.
    """
  end

  # ---- roster resolution -------------------------------------------------

  defp resolve_roster(%Task{} = _task, :user, _on_event) do
    roster =
      Egghead.search_by_class(:agent)
      |> Enum.reject(&(&1.id == Judge.id()))

    {:ok, [], roster}
  end

  defp resolve_roster(%Task{personas: []} = _task, :task, _on_event) do
    {:error, :task_has_no_personas}
  end

  defp resolve_roster(%Task{personas: ids} = _task, :task, on_event) do
    case Persona.fetch_all(ids) do
      {:ok, records} ->
        emit(on_event, {:spawning_personas, Enum.map(records, & &1.id)})

        started =
          Enum.reduce_while(records, [], fn record, acc ->
            case Egghead.Agent.Supervisor.start_agent(Egghead.Agent.Supervisor, record) do
              {:ok, _pid} -> {:cont, [record.id | acc]}
              {:error, {:already_started, _}} -> {:cont, [record.id | acc]}
              {:error, reason} -> {:halt, {:error, {:persona_start_failed, record.id, reason}}}
            end
          end)

        case started do
          {:error, _} = err ->
            err

          ids_list ->
            {:ok, Enum.reverse(ids_list), records}
        end

      {:error, {:missing, missing}} ->
        {:error, {:missing_personas, missing}}
    end
  end

  # ---- capability gate ---------------------------------------------------

  defp gate_capabilities(%Task{required_capabilities: []} = _task, _roster, _on_event), do: :ok

  defp gate_capabilities(task, roster, on_event) do
    case CapabilityCheck.check(task, roster) do
      :ok ->
        :ok

      {:error, {:missing, _} = missing} ->
        emit(on_event, {:capability_gate, {missing, roster}})
        {:skipped, {:capabilities_missing, missing}}
    end
  end

  # ---- execution ---------------------------------------------------------

  defp execute(task, roster, opts, on_event) do
    started_at = System.monotonic_time(:millisecond)
    agent_ids = Enum.map(roster, & &1.id)
    run_id = Keyword.fetch!(opts, :run_id)

    room_id = "eval-#{run_id}"
    timeout = Keyword.get(opts, :timeout, 300_000)
    mode = task.dialogue_mode || :serial

    room_opts = [
      id: room_id,
      idle_timeout: true,
      mode: mode,
      agents: agent_ids
    ]

    case Egghead.create_room(room_opts) do
      {:ok, ^room_id} ->
        # Verify the Room actually has agents joined. If it's empty,
        # the Coordinator has nothing to scope to and the prompt will
        # drop into silence until the idle timeout. Surface this loudly.
        joined =
          case Room.get_state(room_id) do
            %{agents: list} when is_list(list) -> list
            _ -> []
          end

        if joined == [] do
          Logger.error(
            "Eval runner: room #{room_id} opened with zero joined agents. " <>
              "Requested roster: #{inspect(agent_ids)}. " <>
              "Check that each agent process is alive — see Egghead.agent_info_by_id/1."
          )

          emit(on_event, {:empty_roster, %{room_id: room_id, requested: agent_ids}})
        end

        emit(on_event, {:room_opened, %{room_id: room_id, roster: joined}})
        Room.subscribe(room_id)

        Room.send_message(room_id, task.prompt)

        rounds = max(task.rounds || 1, 1)
        emit(on_event, {:round_started, %{round: 1, of: rounds}})

        # Round 1: wait for the initial activation to settle.
        # `responses` is our own event-driven capture of each agent
        # turn (Room transcript is authoritative, fetched after the
        # loop — but may be gone by then if the Room died, so we
        # keep our own log as a fallback).
        {turns_1, responses_1} =
          collect(on_event, deadline(timeout), 0, 0, 0, [])

        # Rounds 2..N: MARBLE's engine re-invokes every agent per
        # iteration against the accumulated shared memory. We
        # reproduce that by posting a lightweight "continue" nudge
        # — it lands as a user_message, the Coordinator activates
        # every agent in the room again, and each agent sees the
        # full prior transcript (including any artifacts that
        # actually got written to the workspace in round 1).
        {turns, responses} =
          if rounds > 1 do
            Enum.reduce(2..rounds, {turns_1, responses_1}, fn round_n, {t_acc, r_acc} ->
              emit(on_event, {:round_started, %{round: round_n, of: rounds}})
              Room.send_message(room_id, round_prompt(round_n, rounds))
              {t, r} = collect(on_event, deadline(timeout), 0, 0, 0, [])
              {t_acc + t, r_acc ++ r}
            end)
          else
            {turns_1, responses_1}
          end

        transcript =
          safe_room_call(fn -> Room.get_transcript(room_id) end) ||
            responses_to_transcript(room_id, responses)

        transcript_id =
          case safe_room_call(fn -> Room.save_transcript(room_id) end) do
            {:ok, id} -> id
            _ -> nil
          end

        # Snapshot per-room session tokens BEFORE stopping the room —
        # Room.stop/1 terminates each agent's per-room Session, which
        # zeroes the usage we care about. The Session for this room
        # already carries the exact token count for this run.
        tokens = snapshot_room_tokens(room_id, agent_ids)

        safe_room_call(fn -> Egghead.Chat.ToolCache.invalidate(room_id) end)
        safe_room_call(fn -> Room.stop(room_id) end)

        duration_ms = System.monotonic_time(:millisecond) - started_at

        {:ok,
         %{
           run_id: run_id,
           room_id: room_id,
           transcript: transcript,
           transcript_id: transcript_id,
           turns: turns,
           responses: responses,
           duration_ms: duration_ms,
           tokens: tokens
         }}

      {:error, reason} ->
        {:error, {:room_open_failed, reason}}
    end
  end

  # Returns `%{per_agent: %{id => %{input, output}}, total: %{input, output}}`
  # by inspecting each agent's per-room Session state directly.
  #
  # Why not diff `Egghead.list_agents/0` usage before and after the
  # run: `list_agents` aggregates across live sessions. Stopping the
  # room kills the per-room Session (the `:EXIT`/`:DOWN` path in
  # `agent.ex`), so the "after" aggregate has the room's tokens
  # removed before we read it. Query the live sessions first.
  defp snapshot_room_tokens(room_id, agent_ids) do
    per_agent =
      Map.new(agent_ids, fn id ->
        {id, agent_session_usage(id, room_id)}
      end)

    total =
      Enum.reduce(per_agent, %{input: 0, output: 0}, fn {_id, %{input: i, output: o}}, acc ->
        %{input: acc.input + i, output: acc.output + o}
      end)

    %{per_agent: per_agent, total: total}
  end

  # Wrap a Room.* call that might exit because the Room process
  # terminated (idle timeout race, explicit stop from another caller,
  # crash). Returns nil on exit so the caller can fall back.
  defp safe_room_call(fun) do
    try do
      fun.()
    catch
      :exit, _ -> nil
      _, _ -> nil
    end
  end

  # Fallback transcript when the Room is gone: reconstruct a minimal
  # message list from the events we captured during `collect/6`. Loses
  # timestamps/mentions/usage but keeps enough for the judge.
  defp responses_to_transcript(room_id, responses) do
    Enum.map(responses, fn %{agent: id, text: text} ->
      %{
        id: nil,
        room_id: room_id,
        sender: %{type: :agent, id: id, name: id},
        content: text,
        timestamp: DateTime.utc_now(),
        mentions: []
      }
    end)
  end

  defp agent_session_usage(agent_id, room_id) do
    try do
      with agent_pid when is_pid(agent_pid) <-
             GenServer.whereis(Egghead.Agent.agent_name(agent_id)),
           %{sessions: sessions} <- :sys.get_state(agent_pid),
           session_pid when is_pid(session_pid) <- Map.get(sessions, room_id),
           %{usage: %{input_tokens: i, output_tokens: o}} <- :sys.get_state(session_pid) do
        %{input: i, output: o}
      else
        _ -> %{input: 0, output: 0}
      end
    catch
      _, _ -> %{input: 0, output: 0}
    end
  end

  defp collect(on_event, deadline, expected, received, turns, responses) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:agents_activated, count} ->
        collect(on_event, deadline, expected + count, received, turns, responses)

      {:agent_message, msg} ->
        emit(on_event, {:turn, msg})
        responses = responses ++ [%{agent: msg.sender.id, text: msg.content}]
        maybe_done(on_event, deadline, expected, received + 1, turns + 1, responses)

      {:agent_passed, agent_id} ->
        emit(on_event, {:pass, agent_id})
        maybe_done(on_event, deadline, expected, received + 1, turns, responses)

      :budget_exhausted ->
        {turns, responses}

      _ ->
        collect(on_event, deadline, expected, received, turns, responses)
    after
      remaining -> {turns, responses}
    end
  end

  defp maybe_done(on_event, deadline, expected, received, turns, responses)
       when expected > 0 and received >= expected do
    receive do
      {:agents_activated, count} ->
        collect(on_event, deadline, expected + count, received, turns, responses)

      {:agent_message, msg} ->
        emit(on_event, {:turn, msg})
        responses = responses ++ [%{agent: msg.sender.id, text: msg.content}]
        maybe_done(on_event, deadline, expected, received + 1, turns + 1, responses)

      {:agent_passed, agent_id} ->
        emit(on_event, {:pass, agent_id})
        maybe_done(on_event, deadline, expected, received + 1, turns, responses)
    after
      2_000 -> {turns, responses}
    end
  end

  defp maybe_done(on_event, deadline, expected, received, turns, responses) do
    collect(on_event, deadline, expected, received, turns, responses)
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  # ---- cleanup -----------------------------------------------------------

  defp cleanup_transients([]), do: :ok

  defp cleanup_transients(ids) do
    Enum.each(ids, fn id ->
      _ = Egghead.Agent.Supervisor.stop_agent(Egghead.Agent.Supervisor, id)
    end)
  end

  # ---- scoring + persistence ---------------------------------------------

  defp finalize(task, run_state, roster, mode, opts, on_event) do
    emit(on_event, {:judging, %{turns: run_state.turns}})
    judge_model = Keyword.get(opts, :judge_model)

    score_result =
      Scorer.grade(task, run_state.transcript,
        roster: Enum.map(roster, & &1.id),
        judge_model: judge_model
      )

    case score_result do
      {:ok, score} ->
        emit(on_event, {:scored, score})

        record_opts = %{
          run_id: run_state.run_id,
          task: task,
          score: score,
          roster: Enum.map(roster, & &1.id),
          transcript_id: run_state.transcript_id,
          duration_ms: run_state.duration_ms,
          turns: run_state.turns,
          roster_mode: mode,
          judge_model: judge_model,
          tokens: run_state[:tokens]
        }

        attrs = Reporter.to_record_attrs(record_opts)

        base = %{
          run_id: run_state.run_id,
          task_id: task.id,
          transcript_id: run_state.transcript_id,
          score: score,
          roster: Enum.map(roster, & &1.id),
          tokens: run_state[:tokens],
          turns: run_state.turns,
          duration_ms: run_state.duration_ms
        }

        case Egghead.create_record(attrs) do
          {:ok, record} ->
            emit(on_event, {:persisted, record.id})
            Map.merge(base, %{record_id: record.id, status: :ok, reason: nil})

          {:error, reason} ->
            Logger.warning(
              "Eval run #{run_state.run_id}: failed to persist record: #{inspect(reason)}"
            )

            Map.merge(base, %{
              record_id: nil,
              status: :error,
              reason: {:persist_failed, reason}
            })
        end

      {:error, reason} ->
        Logger.warning("Eval run #{run_state.run_id}: judge failed: #{inspect(reason)}")

        %{
          run_id: run_state.run_id,
          task_id: task.id,
          record_id: nil,
          transcript_id: run_state.transcript_id,
          score: nil,
          roster: Enum.map(roster, & &1.id),
          tokens: run_state[:tokens],
          turns: run_state.turns,
          duration_ms: run_state.duration_ms,
          status: :error,
          reason: {:judge_failed, reason}
        }
    end
  end

  # ---- misc --------------------------------------------------------------

  defp mint_run_id do
    date = Date.utc_today() |> Date.to_iso8601()
    hash = :crypto.strong_rand_bytes(2) |> Base.encode16(case: :lower)
    "#{date}-#{hash}"
  end

  defp emit(fun, event) when is_function(fun, 1), do: fun.(event)
  defp emit(_, _), do: :ok
end
