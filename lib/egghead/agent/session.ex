defmodule Egghead.Agent.Session do
  @moduledoc """
  A per-room conversation session for an agent.

  Holds session-scoped state (history, token usage, referenced records) and
  executes prompts using identity from the parent agent. Each room gets its
  own session so conversation history doesn't bleed across rooms.

  Sessions monitor their room process and stop when the room dies.
  A "default" session (room_id = nil) handles 1:1 prompts outside rooms.
  """

  use GenServer

  require Logger

  alias Egghead.LLM.Registry

  @max_tool_rounds 20
  @max_protected_results 2
  @compact_threshold 200
  @body_cap 500
  # How many recent room messages to replay into state.history when
  # a session is created mid-conversation or rehydrates after a
  # handoff. Deeper history can always be searched via record tools.
  @backfill_limit 50

  @base_system_prompt_intro """
  You are an agent in Egghead, a shared knowledge base. Records are Markdown
  (with YAML frontmatter) or org-mode files, each with an id, title, tags,
  links to other records, a class (durable, inbox, deliberation, agent), and
  a body. Records are linked with [[wikilinks]]. When you reference a record
  in your response, always use [[wikilink]] syntax (e.g. [[record-id]]).
  This makes records navigable in the interface.
  """

  # Tool-aware paragraph — only included when the agent actually has
  # tools available. Otherwise, telling the LLM to "use your tools"
  # makes it hallucinate XML <invoke> tags as plain text.
  @base_system_prompt_tools """

  Use your tools to search and read records — don't guess about what's in
  the store. Reference records by their id. Create records to persist
  valuable knowledge, using meaningful ids and linking to related records.
  """

  # When an agent has no tools (`capabilities: []`), say so explicitly.
  # Without this, tool-less agents — which can only pattern-match on
  # context — will happily confabulate about having read records or
  # searched the store when prompted. Grounding boundary must be stated.
  @base_system_prompt_no_tools """

  You have no tools. You cannot search records, read files, or verify
  claims against the store. If a question requires looking something up,
  say you'd need to — do not invent record contents, search results,
  or details you cannot actually see. Speak from pattern, analysis, and
  synthesis, not from pretended access.
  """

  @base_system_prompt_outro """

  Be concise and substantive.
  """

  @chat_addendum """
  You are in a shared chat room with other agents and a human.

  Your conversation history shows turns from the human and from other
  agents, prefixed with their name (e.g. `agents/scout: ...` or
  `mark: ...`). These are OTHER voices — not your prior turns, not
  prompts directed only at you. Do not mirror them: don't repackage
  a peer's point as your own contribution, don't adopt their framing
  wholesale, don't continue their message in first person.

  If the human asks you to recall, paraphrase, or summarize what a
  peer said, do it directly.

  Speak when you have something substantive to add:
  - Records, information, or analysis others haven't mentioned
  - A correction to a factual error
  - Synthesis across what's been said
  - A sharpening question or a reservation worth naming
  - An adjacent observation the discussion would benefit from

  Yield with /pass when you truly have nothing to add — not as a safe
  default, but as an honest read. /pass must be your complete response,
  on its own line, nothing before or after. A direct question from the
  human is not a pass situation — answer it.

  Other conventions:
  - Address agents with @id to activate them.
  - Speak in first person — "I", not your own name in third person.
  - Do not restart a search another agent already ran — build on their
    result or correct it.
  - Keep responses brief.
  """

  @huddle_addendum """

  The human has asked for input from every agent in this room. Contribute
  one honest line — agreement, a reservation, a sharpening question, or
  something adjacent you noticed. /pass is not allowed in this mode;
  silence breaks the huddle. Be brief.
  """

  @jam_addendum """

  Low threshold for speaking up — partial thoughts, half-formed ideas,
  tangents, and overlaps are welcome. You are firing in parallel with
  other agents and won't see their output before you respond; don't try
  to coordinate. Keep it short and associative — this is cacophony, not
  consensus.
  """

  defmodule State do
    @moduledoc false

    defstruct [
      :agent_id,
      :room_id,
      :identity,
      history: [],
      usage: %{input_tokens: 0, output_tokens: 0},
      # Cumulative lifetime API spend for this session (input+output across
      # all calls, across all prompts). Useful for cost tracking; NOT a
      # measure of current context footprint.
      session_tokens: 0,
      # Actual context footprint at end of the last prompt: the last
      # LLM call's input_tokens + output_tokens. This is what "70% of
      # the window" should compare against — not the cumulative counter.
      current_context_tokens: 0,
      context_window: nil,
      context_threshold: 0.80,
      referenced_records: MapSet.new(),
      # Async machinery — LLM work runs in a supervised Task, not
      # inside handle_call. While a task is in flight, the GenServer
      # mailbox keeps draining: peer messages, /user messages, and
      # quick queries (usage, clear_history) continue to work.
      #
      # pending_task: %{ref: ref, from: from, kind: :prompt/:handoff/:save,
      #                 input_history_len: n} | nil
      # queued_calls: list of {from, call_tuple} waiting for the
      #               current task to finish. One LLM-driving call at
      #               a time per session, preserving the prior
      #               behaviour of serial prompts per agent-in-room.
      pending_task: nil,
      queued_calls: []
    ]
  end

  # --- Public API ---

  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    room_id = Keyword.get(opts, :room_id)
    name = session_name(agent_id, room_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec prompt(pid() | atom(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def prompt(session, message, opts \\ []) do
    GenServer.call(session, {:prompt, message, opts}, 300_000)
  end

  @spec handoff(pid() | atom(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def handoff(session, opts \\ []) do
    GenServer.call(session, {:handoff, opts}, 300_000)
  end

  @spec save(pid() | atom()) :: {:ok, String.t()} | {:error, term()}
  def save(session) do
    GenServer.call(session, :save, 300_000)
  end

  @doc """
  Returns the registered name for a session process.
  """
  @spec session_name(String.t(), String.t() | nil) :: atom()
  def session_name(agent_id, nil), do: :"egghead_session_#{agent_id}_default"
  def session_name(agent_id, room_id), do: :"egghead_session_#{agent_id}_#{room_id}"

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    room_id = Keyword.get(opts, :room_id)
    identity = Keyword.fetch!(opts, :identity)
    room_pid = Keyword.get(opts, :room_pid)

    # Identity is snapshotted at spawn time — intentionally not fetched
    # dynamically from the parent agent. This mirrors OTP's model: existing
    # sessions finish on current identity, new sessions get updated identity
    # if the agent record changes. Do not "fix" this with a dynamic lookup.

    # Monitor the room process so we stop when it dies
    if room_pid, do: Process.monitor(room_pid)

    # Subscribe to the room's PubSub topic so we can append peer and
    # user messages to state.history as they're broadcast. This is the
    # AutoGen-style pattern: peer content lives in the conversation
    # array (strong attention channel), not in the system prompt (weak).
    # Default sessions (room_id = nil) don't subscribe — nothing to listen to.
    if room_id do
      Phoenix.PubSub.subscribe(Egghead.PubSub, Egghead.Chat.Room.topic(room_id))
    end

    # Rehydrate history from the room's current transcript. When this
    # session is first created mid-conversation — or after a handoff
    # cleared history — it needs to catch up on what's already been said.
    # Capped at the last @backfill_limit messages to keep the prompt sane.
    history =
      if room_id do
        rehydrate_history_from_transcript(room_id, agent_id)
      else
        []
      end

    state = %State{
      agent_id: agent_id,
      room_id: room_id,
      identity: identity,
      history: history,
      context_window: identity[:context_window],
      context_threshold: identity[:context_threshold] || 0.80
    }

    Logger.debug(
      "Session started: #{agent_id} in #{room_id || "default"} " <>
        "(rehydrated #{length(history)} turns)"
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:prompt, message, opts}, from, state) do
    dispatch_or_queue(state, from, {:prompt, message, opts})
  end

  def handle_call({:handoff, opts}, from, state) do
    dispatch_or_queue(state, from, {:handoff, opts})
  end

  def handle_call(:save, from, state) do
    dispatch_or_queue(state, from, :save)
  end

  @impl true
  # Task finished normally — apply its result to state, reply to
  # whoever was waiting, then dispatch the next queued call (if any).
  def handle_info({ref, task_result}, %{pending_task: %{ref: ref} = pt} = state) do
    Process.demonitor(ref, [:flush])
    {reply, state} = apply_task_result(state, pt, task_result)
    GenServer.reply(pt.from, reply)
    dispatch_queue(%{state | pending_task: nil})
  end

  # Task crashed — reply with an error so the caller isn't stuck, then
  # drain the queue. Matches on the pending_task ref so we don't
  # conflict with the room-monitor DOWN handler below.
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{pending_task: %{ref: ref} = pt} = state
      ) do
    Logger.warning(
      "Session #{state.agent_id}/#{state.room_id}: #{pt.kind} task crashed: #{inspect(reason)}"
    )

    GenServer.reply(pt.from, {:error, {:task_crashed, reason}})
    dispatch_queue(%{state | pending_task: nil})
  end

  # Room process died — stop the session.
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    Logger.debug("Session #{state.agent_id}/#{state.room_id}: room process died, stopping")
    {:stop, :normal, state}
  end

  # Peer agent posted to the room — append to history as a user turn
  # with name-prefixed content. Ignore our own messages (they're
  # already in history via agent_loop's assistant turn). Skip pure
  # /pass messages — the atmospheric flavor render in the UI is the
  # only consumer of /pass semantics; they add noise to conversation.
  def handle_info({:agent_message, msg}, state) do
    cond do
      msg.sender.id == state.agent_id ->
        {:noreply, state}

      msg.content == "/pass" ->
        {:noreply, state}

      true ->
        entry = %{role: "user", content: "#{msg.sender.id}: #{msg.content}"}
        {:noreply, %{state | history: state.history ++ [entry]}}
    end
  end

  # Human posted to the room — append as a user turn with the human's
  # display name prefixed. This is what the agent "sees" when they're
  # next activated.
  def handle_info({:user_message, msg}, state) do
    entry = %{role: "user", content: "#{msg.sender.name}: #{msg.content}"}
    {:noreply, %{state | history: state.history ++ [entry]}}
  end

  # User hit /halt or ESC. Abort the in-flight LLM task (closes the
  # streaming SSE connection and drops any pending tool result), reply
  # to whoever was blocked on the call, and reject any queued calls so
  # callers don't hang. The Session itself stays alive — agents are
  # silenced for this turn, not removed. New prompts after this point
  # are gated by Coordinator.run_agent_attempt, which checks the Room's
  # authoritative halted state.
  def handle_info({:halted, _room_id}, state) do
    state =
      case state.pending_task do
        nil ->
          state

        %{ref: ref, pid: pid, from: from} ->
          Process.demonitor(ref, [:flush])
          Process.exit(pid, :kill)
          GenServer.reply(from, {:error, :halted})
          %{state | pending_task: nil}
      end

    Enum.each(state.queued_calls, fn {from, _call} ->
      GenServer.reply(from, {:error, :halted})
    end)

    {:noreply, %{state | queued_calls: []}}
  end

  # Room events we don't need to act on (other agents' lifecycle,
  # streaming chunks, etc.). Ignore silently — we're only listening
  # for commits (agent_message / user_message).
  def handle_info(_event, state), do: {:noreply, state}

  # --- Async dispatch machinery ---

  # Route an LLM-driving call (prompt / handoff / save) either to a
  # fresh task if nothing is in flight, or onto the queue. Callers
  # block on `GenServer.call`; we reply via `GenServer.reply` when
  # the task eventually finishes. From the caller's perspective
  # nothing changes — it's still a synchronous `GenServer.call` that
  # eventually returns the result.
  defp dispatch_or_queue(%{pending_task: nil} = state, from, call) do
    start_task(state, from, call)
  end

  defp dispatch_or_queue(state, from, call) do
    {:noreply, %{state | queued_calls: state.queued_calls ++ [{from, call}]}}
  end

  defp dispatch_queue(%{queued_calls: []} = state), do: {:noreply, state}

  defp dispatch_queue(%{queued_calls: [{from, call} | rest]} = state) do
    start_task(%{state | queued_calls: rest}, from, call)
  end

  defp start_task(state, from, call) do
    snapshot = snapshot_for_task(state)
    input_history_len = length(state.history)

    {kind, task_fn} =
      case call do
        {:prompt, message, opts} ->
          {:prompt, fn -> run_prompt_task(snapshot, message, opts) end}

        {:handoff, opts} ->
          # Coordinator watches for this to avoid activating the agent
          # during the summary window. Must fire BEFORE the task
          # starts — fire it inline here, not inside the task.
          room_id = Keyword.get(opts, :room_id, state.room_id)
          if room_id, do: broadcast_handoff_started(room_id, state.agent_id)

          Logger.info(
            "Handoff started: #{state.agent_id} in #{room_id || "default"} " <>
              "(#{length(state.history)} history messages, #{state.session_tokens} tokens)"
          )

          {:handoff, fn -> run_handoff_task(snapshot, opts) end}

        :save ->
          {:save, fn -> run_save_task(snapshot) end}
      end

    task = Task.Supervisor.async_nolink(Egghead.Tool.TaskSupervisor, task_fn)

    pending = %{
      ref: task.ref,
      pid: task.pid,
      from: from,
      kind: kind,
      input_history_len: input_history_len,
      call: call
    }

    {:noreply, %{state | pending_task: pending}}
  end

  # Fields the task needs; passed by value so task mutations don't
  # race with handle_info mutating state.history on peer broadcasts.
  defp snapshot_for_task(state) do
    %{
      agent_id: state.agent_id,
      room_id: state.room_id,
      identity: state.identity,
      history: state.history,
      usage: state.usage,
      session_tokens: state.session_tokens,
      current_context_tokens: state.current_context_tokens,
      context_window: state.context_window,
      context_threshold: state.context_threshold,
      referenced_records: state.referenced_records
    }
  end

  # --- Task result application ---

  # Prompt finished. Compute the delta (turns the LLM added beyond
  # what it saw as input) and append them to the CURRENT state.history
  # — which may have grown while the task ran, because peer messages
  # were appended in handle_info. That's the whole point: the agent's
  # next prompt sees the current room, not a frozen-in-time snapshot.
  defp apply_task_result(
         state,
         %{kind: :prompt, input_history_len: input_len},
         {:ok, result}
       ) do
    summary_info = result.summary

    # If summarization happened mid-task, re-rehydrate from the live
    # transcript so we capture peers that spoke during both the
    # summary AND prompt phases. The task rehydrated once, but that
    # snapshot was taken mid-work; the current transcript is newer.
    state =
      case summary_info do
        nil ->
          state

        %{delib_id: delib_id} ->
          rehydrated =
            if state.room_id,
              do: rehydrate_history_from_transcript(state.room_id, state.agent_id),
              else: []

          %{
            state
            | history: rehydrated,
              session_tokens: 0,
              current_context_tokens: 0,
              referenced_records: MapSet.new([delib_id])
          }
      end

    # Delta = turns the task's LLM loop added beyond its input.
    # `result.task_input_history_len` tells us how long the task's
    # input was (which may differ from state.history because of
    # summarization inside the task).
    delta = Enum.drop(result.final_history, result.task_input_history_len)
    _ = input_len

    total_usage = result.total_usage
    last_call_usage = result.last_call_usage
    current_context_tokens = last_call_usage.input_tokens + last_call_usage.output_tokens

    state = %{
      state
      | history: state.history ++ delta,
        usage: %{
          input_tokens: state.usage.input_tokens + total_usage.input_tokens,
          output_tokens: state.usage.output_tokens + total_usage.output_tokens
        },
        session_tokens:
          state.session_tokens + total_usage.input_tokens + total_usage.output_tokens,
        current_context_tokens: current_context_tokens,
        referenced_records: MapSet.union(state.referenced_records, result.refs)
    }

    context_pct =
      if state.context_window && state.context_window > 0,
        do: Float.round(current_context_tokens / state.context_window * 100, 1),
        else: nil

    response = %Egghead.Agent.Response{
      text: result.final_text,
      agent_id: state.agent_id,
      model: state.identity[:model],
      usage:
        Map.merge(total_usage, %{
          session_tokens: state.session_tokens,
          current_context_tokens: current_context_tokens,
          context_window: state.context_window,
          context_pct: context_pct
        }),
      tool_calls: result.tool_log,
      records_created: result.created,
      records_updated: result.updated,
      duration_ms: result.duration_ms
    }

    {{:ok, response}, state}
  end

  defp apply_task_result(state, %{kind: :prompt}, {:error, reason}) do
    {{:error, reason}, state}
  end

  # Handoff finished. On success, clear state and re-rehydrate from the
  # transcript (captures peers that arrived during the summary window).
  defp apply_task_result(
         state,
         %{kind: :handoff, call: {:handoff, opts}},
         {:ok, %{delib_id: delib_id, duration_ms: elapsed} = result}
       ) do
    room_id = Keyword.get(opts, :room_id, state.room_id)

    Logger.info(
      "Handoff complete: #{state.agent_id} in #{room_id || "default"} " <>
        "→ #{delib_id} (#{elapsed}ms)"
    )

    if room_id, do: broadcast_handoff(room_id, state.agent_id, delib_id)

    rehydrated =
      if state.room_id,
        do: rehydrate_history_from_transcript(state.room_id, state.agent_id),
        else: []

    state = %{
      state
      | history: rehydrated,
        session_tokens: 0,
        current_context_tokens: 0,
        referenced_records: MapSet.new([delib_id])
    }

    reply =
      case result do
        %{next_prompt_response: resp} when resp != nil -> {:ok, delib_id, resp}
        _ -> {:ok, delib_id}
      end

    {reply, state}
  end

  defp apply_task_result(state, %{kind: :handoff}, {:error, reason}) do
    Logger.warning(
      "Handoff failed: #{state.agent_id} in #{state.room_id || "default"}: #{inspect(reason)}"
    )

    {{:error, reason}, state}
  end

  # Save is a read-only operation from the state's perspective — the
  # LLM may have written records via tools, but session state doesn't
  # change. Just reply with the response.
  defp apply_task_result(state, %{kind: :save}, {:ok, response}) do
    {{:ok, response}, state}
  end

  defp apply_task_result(state, %{kind: :save}, {:error, reason}) do
    {{:error, reason}, state}
  end

  # --- Task bodies (run in a spawned process, not in the GenServer) ---

  defp run_prompt_task(snapshot, message, opts) do
    # Decide if auto-summarization is needed BEFORE the prompt.
    # Both phases happen inside the same task so the caller sees
    # one reply for the whole operation.
    {snapshot, summary_info} =
      if should_summarize?(snapshot) do
        case do_summarize_to_deliberation_snapshot(snapshot) do
          {:ok, delib_id, new_snapshot} ->
            if room_id = snapshot.room_id do
              broadcast_handoff(room_id, snapshot.agent_id, delib_id)
            end

            {new_snapshot, %{delib_id: delib_id}}

          {:error, _reason, snapshot} ->
            {snapshot, nil}
        end
      else
        {snapshot, nil}
      end

    case do_prompt_snapshot(snapshot, message, opts) do
      {:ok, prompt_result} ->
        {:ok, Map.put(prompt_result, :summary, summary_info)}

      {:error, _} = err ->
        err
    end
  end

  defp run_handoff_task(snapshot, opts) do
    started_at = System.monotonic_time(:millisecond)
    next_prompt = Keyword.get(opts, :next_prompt)

    case do_summarize_to_deliberation_snapshot(snapshot) do
      {:ok, delib_id, new_snapshot} ->
        elapsed = System.monotonic_time(:millisecond) - started_at

        next_response =
          if next_prompt do
            case do_prompt_snapshot(new_snapshot, next_prompt, []) do
              {:ok, %{final_text: text}} -> text
              _ -> nil
            end
          end

        {:ok,
         %{
           delib_id: delib_id,
           duration_ms: elapsed,
           next_prompt_response: next_response
         }}

      {:error, reason, _} ->
        {:error, reason}
    end
  end

  defp run_save_task(snapshot) do
    do_save_snapshot(snapshot)
  end

  # --- Prompt execution (snapshot-based; runs inside a task) ---
  #
  # Returns a map of everything the GenServer needs to merge back
  # into its live state — deliberately stateless so the task doesn't
  # race with handle_info mutations on state.history. The caller
  # (apply_task_result) computes delta vs. its live history and
  # appends, so peers who spoke during the task aren't lost.

  defp do_prompt_snapshot(snapshot, message, opts) do
    id = snapshot.identity
    room = Keyword.get(opts, :room)
    system_prompt = build_system_prompt(snapshot, room)

    compacted = compact_history(snapshot.history)

    # In rooms, the coordinator calls with an empty message — the
    # triggering user/peer turn is already in snapshot.history via the
    # broadcast subscription. For non-room 1:1 prompts, the message
    # is the user turn and gets appended.
    history =
      case message do
        "" -> compacted
        nil -> compacted
        _ -> compacted ++ [%{role: "user", content: message}]
      end

    # Newer Claude models (Opus 4.5+, extended-thinking modes) reject
    # messages ending with an assistant turn — they interpret it as
    # prefill, which isn't supported. This happens when a session is
    # re-activated via @-mention before the peer's agent_message has
    # been processed (PubSub is async; mailbox ordering isn't guaranteed
    # against the GenServer.call). Ensure we always send a final user
    # turn.
    history = ensure_trailing_user_turn(history)

    task_input_history_len = length(history)

    tools = Egghead.Agent.Tools.definitions_for(id[:capabilities] || [])

    llm_opts =
      [
        model: id[:model],
        system: system_prompt,
        max_tokens: id[:max_tokens] || 4096
      ]
      |> maybe_opt(:temperature, id[:temperature])
      |> maybe_opt(:thinking, id[:thinking])
      |> maybe_opt(:tools, if(tools != [], do: tools))
      |> Keyword.merge(Keyword.take(opts, [:max_tokens, :temperature, :api_key]))

    llm_opts =
      case Keyword.get(opts, :on_chunk) do
        nil -> llm_opts
        cb -> Keyword.put(llm_opts, :on_chunk, cb)
      end

    start_time = System.monotonic_time(:millisecond)
    room_id = if room, do: room.id, else: snapshot.room_id

    case agent_loop(snapshot, history, llm_opts, room_id, 0) do
      {:ok, final_text, final_history, total_usage, last_call_usage, tool_log} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        {created, updated} = partition_record_mutations(tool_log)
        refs = extract_refs_from_tool_log(tool_log)

        {:ok,
         %{
           final_text: final_text,
           final_history: final_history,
           task_input_history_len: task_input_history_len,
           total_usage: total_usage,
           last_call_usage: last_call_usage,
           tool_log: tool_log,
           created: created,
           updated: updated,
           refs: refs,
           duration_ms: duration_ms
         }}

      {:error, _} = error ->
        error
    end
  end

  # --- Agentic loop ---

  defp agent_loop(_state, _history, _opts, _room_id, round) when round >= @max_tool_rounds do
    {:error, :max_tool_rounds_exceeded}
  end

  defp agent_loop(state, history, opts, room_id, round) do
    case call_llm(state.identity[:model], history, opts) do
      {:ok, %{content: content, stop_reason: stop_reason, usage: usage}} ->
        input_tokens = usage[:input_tokens] || 0
        output_tokens = usage[:output_tokens] || 0
        this_call_usage = %{input_tokens: input_tokens, output_tokens: output_tokens}

        if stop_reason == "tool_use" do
          tool_uses = Enum.filter(content, &(&1["type"] == "tool_use"))

          # Run tool calls concurrently under a supervised Task —
          # crashes (runaway regex, hung HTTP, NIF fault) die in
          # their task, not the Session. `ordered: true` keeps
          # tool_results aligned with their tool_use blocks.
          {tool_results, tool_log} =
            Task.Supervisor.async_stream_nolink(
              Egghead.Tool.TaskSupervisor,
              tool_uses,
              fn tool_use -> run_single_tool(tool_use, state, room_id) end,
              max_concurrency: 5,
              ordered: true,
              timeout: :infinity,
              on_timeout: :kill_task
            )
            |> Enum.map(fn
              {:ok, result} -> result
              {:exit, reason} -> tool_crash_result(reason)
            end)
            |> Enum.unzip()

          history =
            history ++
              [
                %{role: "assistant", content: content},
                %{role: "user", content: tool_results}
              ]

          case agent_loop(state, history, opts, room_id, round + 1) do
            {:ok, text, history, more_usage, last_call_usage, more_log} ->
              merged_usage = %{
                input_tokens: this_call_usage.input_tokens + more_usage.input_tokens,
                output_tokens: this_call_usage.output_tokens + more_usage.output_tokens
              }

              {:ok, text, history, merged_usage, last_call_usage, tool_log ++ more_log}

            error ->
              error
          end
        else
          text =
            content
            |> Enum.filter(&(&1["type"] == "text"))
            |> Enum.map_join("\n", & &1["text"])

          history = history ++ [%{role: "assistant", content: content}]

          # Terminal (non-tool_use) call: its own usage IS the final
          # context footprint — history + system prompt sent as input,
          # plus the output just generated.
          {:ok, text, history, this_call_usage, this_call_usage, []}
        end

      {:error, _} = error ->
        error
    end
  end

  # --- Context management ---

  defp should_summarize?(%{context_window: nil}), do: false

  defp should_summarize?(state) do
    state.context_window != nil and
      state.current_context_tokens > state.context_window * state.context_threshold and
      length(state.history) > 0
  end

  defp do_summarize_to_deliberation_snapshot(snapshot) do
    if snapshot.history == [] do
      {:error, :no_history, snapshot}
    else
      id = snapshot.identity

      summary_prompt = """
      Summarize this conversation for your own future reference. Include:
      - Key topics discussed and conclusions reached
      - Open questions or unresolved threads
      - Record ids that were important to the discussion
      - Any decisions or insights worth preserving

      Be thorough but concise. This summary will be stored as a deliberation
      record and used as context for future conversations.
      """

      messages = snapshot.history ++ [%{role: "user", content: summary_prompt}]

      llm_opts = [
        model: id[:model],
        system: build_system_prompt(snapshot),
        max_tokens: id[:max_tokens] || 4096
      ]

      case call_llm(id[:model], messages, llm_opts) do
        {:ok, %{content: content}} ->
          summary =
            content
            |> Enum.filter(&(&1["type"] == "text"))
            |> Enum.map_join("\n", & &1["text"])

          if String.trim(summary) == "" do
            Logger.warning(
              "Agent #{id[:name]}: summary LLM returned empty text — refusing to write blank deliberation"
            )

            {:error, :empty_summary, snapshot}
          else
            delib_id = "deliberation/#{snapshot.agent_id}/#{timestamp_id()}"
            ref_ids = MapSet.to_list(snapshot.referenced_records)

            attrs = %{
              "id" => delib_id,
              "title" => "Deliberation: #{id[:name]} — #{Date.utc_today()}",
              "tags" =>
                ["deliberation", "agent:#{snapshot.agent_id}"] ++
                  if(snapshot.room_id, do: ["room:#{snapshot.room_id}"], else: []),
              "links" => ref_ids,
              "class" => "deliberation",
              "author" => snapshot.agent_id,
              "body" => summary
            }

            case Egghead.create_record(attrs) do
              {:ok, _record} ->
                Logger.info("Agent #{id[:name]} created deliberation: #{delib_id}")

              {:error, reason} ->
                Logger.warning("Agent #{id[:name]} deliberation failed: #{inspect(reason)}")
            end

            # Rehydrate from the room so the subsequent prompt (inside
            # the same task) sees the short-term conversational floor.
            # The GenServer will re-rehydrate again in apply_task_result
            # to capture anything that arrived during the task.
            rehydrated =
              if snapshot.room_id do
                rehydrate_history_from_transcript(snapshot.room_id, snapshot.agent_id)
              else
                []
              end

            new_snapshot = %{
              snapshot
              | history: rehydrated,
                session_tokens: 0,
                current_context_tokens: 0,
                referenced_records: MapSet.new([delib_id])
            }

            {:ok, delib_id, new_snapshot}
          end

        {:error, reason} ->
          {:error, reason, snapshot}
      end
    end
  end

  defp do_save_snapshot(snapshot) do
    if snapshot.history == [] do
      {:error, :no_history}
    else
      id = snapshot.identity

      save_prompt = """
      Review this conversation and identify any insights, decisions, or
      knowledge worth capturing as permanent durable records.

      For each insight, create a record using the ```egghead-record format.
      Each record should:
      - Have a meaningful id and title
      - Be tagged appropriately
      - Link to the records that informed it
      - Be class: durable

      If nothing is worth saving as a permanent record, say so.
      """

      messages = snapshot.history ++ [%{role: "user", content: save_prompt}]

      llm_opts = [
        model: id[:model],
        system: build_system_prompt(snapshot),
        max_tokens: id[:max_tokens] || 4096
      ]

      tools = Egghead.Agent.Tools.definitions_for(id[:capabilities] || [])
      llm_opts = maybe_opt(llm_opts, :tools, if(tools != [], do: tools))

      case agent_loop(snapshot, messages, llm_opts, nil, 0) do
        {:ok, response, _history, _usage, _last_call, _tool_log} ->
          {:ok, response}

        {:error, _} = error ->
          error
      end
    end
  end

  # --- System prompt ---

  defp build_system_prompt(state, room \\ nil) do
    id = state.identity
    context_status = format_context_status(state)
    has_tools? = (id[:capabilities] || []) != []

    intro =
      if has_tools? do
        @base_system_prompt_intro <> @base_system_prompt_tools <> @base_system_prompt_outro
      else
        @base_system_prompt_intro <> @base_system_prompt_no_tools <> @base_system_prompt_outro
      end

    base = """
    #{intro}

    You are **#{id[:name]}** (#{id[:id]}). #{context_status}

    #{id[:disposition]}
    """

    if room do
      agents_list = room.agents |> Enum.join(", ")

      # Peer and human messages live in state.history as role:user
      # turns — the strong attention channel. No need to duplicate
      # them in the system prompt. If history is empty (fresh session
      # whose rehydrate came up empty), we still include a prior-
      # context block from the most recent deliberation record, if any.
      prior_context = if state.history == [], do: room_deliberation_context(room.id)

      activation_addendum =
        case Map.get(room, :activation, :normal) do
          :huddle -> @huddle_addendum
          :jam -> @jam_addendum
          _ -> ""
        end

      base <>
        @chat_addendum <>
        activation_addendum <>
        """

        Room: #{room.id} | Agents: #{agents_list}
        """ <>
        if(prior_context, do: "\n#{prior_context}\n", else: "")
    else
      base
    end
  end

  # Find the most recent deliberation record tagged with this room
  # and return a priming-context block, or nil if none exists.
  defp room_deliberation_context(room_id) do
    case Egghead.Record.Deliberation.latest_for_room(room_id) do
      nil -> nil
      deliberation -> Egghead.Record.Deliberation.context_for_session(deliberation)
    end
  end

  # --- Rehydration ---

  # Convert the last @backfill_limit messages of the room's transcript
  # into history entries (user/assistant role turns) for this agent.
  # Called on session init and after handoff, when history is empty and
  # we need to catch up to the room's current state.
  #
  # - Human messages become user turns with the human's name prefix.
  # - Our own messages become assistant turns (verbatim).
  # - Other agents' messages become user turns with "agents/<id>: " prefix.
  # - /pass messages are skipped — no conversational content.
  defp rehydrate_history_from_transcript(room_id, agent_id) do
    try do
      transcript = Egghead.Chat.Room.get_transcript(room_id)

      history =
        transcript
        |> Enum.take(-@backfill_limit)
        |> Enum.reject(fn m -> m.content == "/pass" end)
        |> Enum.map(fn m ->
          case m.sender do
            %{type: :user, name: name} ->
              %{role: "user", content: "#{name}: #{m.content}"}

            %{type: :agent, id: ^agent_id} ->
              %{role: "assistant", content: m.content}

            %{type: :agent, id: id} ->
              %{role: "user", content: "#{id}: #{m.content}"}

            _ ->
              %{role: "user", content: m.content}
          end
        end)

      # Newer Claude models (Sonnet 4.6+, Opus 4.7+) reject conversations
      # ending with an assistant message ("prefill not supported"). When
      # this agent was the last to speak, reframe the trailing self-message
      # as a user turn so the model sees its prior output as context.
      case List.last(history) do
        %{role: "assistant", content: content} ->
          List.replace_at(history, -1, %{
            role: "user",
            content: "[Your previous response]:\n#{content}"
          })

        _ ->
          history
      end
    catch
      :exit, reason ->
        Logger.warning(
          "Session #{agent_id}: rehydrate failed (#{inspect(reason)}) — starting empty"
        )

        []
    end
  end

  # --- Compaction ---

  defp ensure_trailing_user_turn([]), do: []

  defp ensure_trailing_user_turn(history) do
    case List.last(history) do
      %{role: "assistant"} ->
        history ++ [%{role: "user", content: "(Continue.)"}]

      _ ->
        history
    end
  end

  defp compact_history(history) do
    {protected_ids, _} =
      history
      |> Enum.reverse()
      |> Enum.reduce({MapSet.new(), 0}, fn entry, {ids, count} ->
        case entry do
          %{role: "user", content: content} when is_list(content) ->
            tool_ids =
              content
              |> Enum.filter(&match?(%{type: "tool_result"}, &1))
              |> Enum.map(& &1.tool_use_id)

            remaining = @max_protected_results - count
            newly_protected = Enum.take(tool_ids, max(remaining, 0))
            {MapSet.union(ids, MapSet.new(newly_protected)), count + length(tool_ids)}

          _ ->
            {ids, count}
        end
      end)

    Enum.map(history, fn
      %{role: "user", content: content} = entry when is_list(content) ->
        compacted =
          Enum.map(content, fn
            %{type: "tool_result", tool_use_id: tid, content: text} = result
            when is_binary(text) ->
              if tid in protected_ids do
                cap_large_body(result)
              else
                compact_result(result)
              end

            other ->
              other
          end)

        %{entry | content: compacted}

      entry ->
        entry
    end)
  end

  defp compact_result(%{content: text} = result) when is_binary(text) do
    if String.length(text) > @compact_threshold do
      token_est = div(String.length(text), 4)
      preview = String.slice(text, 0, 100)
      %{result | content: "[Compacted ~#{token_est}tok] #{preview}..."}
    else
      result
    end
  end

  defp compact_result(result), do: result

  defp cap_large_body(%{content: text} = result) when is_binary(text) do
    if String.length(text) > @body_cap do
      token_est = div(String.length(text), 4)
      preview = String.slice(text, 0, @body_cap)

      %{
        result
        | content:
            "#{preview}...\n(~#{token_est}tok total — re-fetch with get_record_body if needed)"
      }
    else
      result
    end
  end

  defp cap_large_body(result), do: result

  defp format_context_status(state) do
    case {state.current_context_tokens, state.context_window} do
      {_, nil} ->
        ""

      {tokens, window} when window > 0 ->
        pct = Float.round(tokens / window * 100, 1)

        cond do
          pct > 70.0 ->
            """
            ## Context Status: #{pct}% (#{tokens}/#{window} tokens)
            Context pressure is HIGH. Summarize rather than quote. Avoid fetching large records.
            Prefer search_records over get_record. If you need a record, use get_record_body for specific sections only.
            """

          pct > 40.0 ->
            """
            ## Context Status: #{pct}% (#{tokens}/#{window} tokens)
            Be selective about which records you fetch. Search first, read only what's necessary.
            """

          true ->
            "## Context Status: #{pct}% used"
        end

      _ ->
        ""
    end
  end

  # --- LLM dispatch ---

  defp call_llm(model_str, messages, opts) do
    result =
      try do
        Registry.resolve(model_str)
      catch
        :exit, _ -> {:error, :registry_unavailable}
      end

    case result do
      {:ok, {module, provider_opts}} ->
        merged = Keyword.merge(opts, provider_opts)
        Code.ensure_loaded(module)

        if Keyword.has_key?(opts, :on_chunk) and function_exported?(module, :chat_stream, 2) do
          module.chat_stream(messages, merged)
        else
          module.chat(messages, merged)
        end

      {:error, {:provider_not_configured, provider}} ->
        {:error,
         "Provider '#{provider}' is not configured. " <>
           "Set the appropriate API key or run `egghead init`. " <>
           "Check the model field in the agent record."}

      {:error, :registry_unavailable} ->
        {:error,
         "No LLM provider available. Set ANTHROPIC_API_KEY, OPENAI_API_KEY, or " <>
           "GOOGLE_API_KEY, or run `egghead init`"}

      {:error, :missing_api_key} ->
        {:error,
         "API key not set for this provider. Set the appropriate environment variable " <>
           "or run `egghead llm add`"}

      {:error, {:transport_error, msg, _raw}} ->
        # Already retried once at the provider layer; surface the human
        # message verbatim so the chat shows e.g. "connection closed by
        # server (transient — retry)" instead of a struct dump.
        {:error, msg}

      {:error, {:api_error, status, body}} ->
        # Pull the actual provider error message out of the response
        # body so the chat shows the why, not a truncated struct dump.
        {:error, "API #{status}: #{api_error_message(body)}"}

      {:error, reason} ->
        {:error, {:provider_error, reason}}
    end
  end

  # Extract a readable message from OpenAI / Gemini / Anthropic error
  # bodies. Falls back to inspecting the body when the shape is unfamiliar.
  defp api_error_message(%{"error" => %{"message" => msg}}) when is_binary(msg), do: msg

  defp api_error_message(%{"error" => %{"message" => msg, "code" => code}}),
    do: "#{code}: #{msg}"

  defp api_error_message(%{"error" => err}) when is_binary(err), do: err
  defp api_error_message(%{"message" => msg}) when is_binary(msg), do: msg
  defp api_error_message(body), do: inspect(body, limit: 5, printable_limit: 400)

  # --- Helpers ---

  defp broadcast_handoff(room_id, agent_id, delib_id) do
    Phoenix.PubSub.broadcast(
      Egghead.PubSub,
      Egghead.Chat.Room.topic(room_id),
      {:agent_handoff, room_id, agent_id, delib_id}
    )
  end

  # Fired BEFORE summarisation begins so the Coordinator can immediately
  # mark the agent in `handoffs_in_progress` and skip activating it
  # during the (often 30-60s) summary window. The matching
  # `:agent_handoff` event fires when summarisation completes.
  defp broadcast_handoff_started(room_id, agent_id) do
    Phoenix.PubSub.broadcast(
      Egghead.PubSub,
      Egghead.Chat.Room.topic(room_id),
      {:agent_handoff_started, room_id, agent_id}
    )
  end

  defp broadcast_denial(nil, _agent_id, _tool_use, _denial), do: :ok

  defp broadcast_denial(room_id, agent_id, tool_use, denial) do
    Phoenix.PubSub.broadcast(
      Egghead.PubSub,
      Egghead.Chat.Room.topic(room_id),
      {:agent_tool_denied, room_id, agent_id, tool_use["name"], tool_use["input"], denial}
    )
  end

  # Per-tool-call runner. Extracted so we can run it inside
  # `Task.Supervisor.async_stream_nolink/5` for parallel execution
  # with crash isolation.
  defp run_single_tool(tool_use, state, room_id) do
    Logger.info(
      "Agent #{state.identity[:name]} calling tool: #{tool_use["name"]}(#{inspect(tool_use["input"])})"
    )

    on_output = build_output_streamer(room_id, state.agent_id, tool_use)

    # Hoisting chain: agent-level sandbox takes precedence over
    # config-level; grant-level `in:` beats both (handled in matcher).
    # The chain only narrows — if an agent declares a sandbox outside
    # the config ceiling, we clamp to config and log loudly.
    raw_agent_sandbox = state.identity[:sandbox]

    config_sandbox =
      case Egghead.Config.load() do
        {:ok, cfg} -> Egghead.Config.sandbox(cfg)
        _ -> nil
      end

    agent_sandbox = clamp_agent_sandbox(raw_agent_sandbox, config_sandbox, state.agent_id)

    ctx = %{
      agent_id: state.agent_id,
      room_id: room_id,
      capabilities: state.identity[:capabilities] || [],
      on_tool_output: on_output,
      agent_sandbox: agent_sandbox,
      config_sandbox: config_sandbox,
      # Pre-resolved profile for subprocess spawning, or nil if the
      # agent holds no external sandbox roots.
      sandbox: build_sandbox_profile(agent_sandbox, config_sandbox)
    }

    {status, result_text} =
      case Egghead.Agent.Tools.execute(tool_use["name"], tool_use["input"], ctx) do
        {:ok, text} ->
          {:ok, text}

        {:error, text} ->
          {:error, text}

        {:denied, %Egghead.Capability.Denial{} = denial} ->
          broadcast_denial(room_id, state.agent_id, tool_use, denial)
          {:error, Egghead.Capability.Denial.to_tool_result(denial)}
      end

    tool_result = %{
      type: "tool_result",
      tool_use_id: tool_use["id"],
      content: result_text,
      is_error: status == :error
    }

    log_entry = %{
      name: tool_use["name"],
      input: tool_use["input"],
      result: result_text,
      error: status == :error
    }

    {tool_result, log_entry}
  end

  # Fallback when a tool Task crashes — we still need a tool_result
  # with the right shape so the LLM can continue. Note we lose the
  # tool_use_id; that's OK for the "tool literally exploded" edge case
  # because Anthropic accepts a tool_result with a missing id as long
  # as the sequencing is intact.
  defp tool_crash_result(reason) do
    msg = "Tool crashed: #{inspect(reason)}"

    tool_result = %{
      type: "tool_result",
      content: msg,
      is_error: true
    }

    log_entry = %{
      name: "(unknown — task crash)",
      input: %{},
      result: msg,
      error: true
    }

    {tool_result, log_entry}
  end

  # Builds an on_tool_output callback for tools that support streaming
  # (currently `shell_exec`). Each chunk broadcasts an
  # `:agent_tool_output` event that the TUI/web renders incrementally.
  defp build_output_streamer(nil, _agent_id, _tool_use), do: nil

  defp build_output_streamer(room_id, agent_id, tool_use) do
    fn chunk ->
      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        Egghead.Chat.Room.topic(room_id),
        {:agent_tool_output, room_id, agent_id, tool_use["name"], tool_use["id"], chunk}
      )
    end
  end

  # Record ids the agent passed as tool inputs (`id` or `ids`).
  defp extract_refs_from_tool_log(tool_log) do
    tool_log
    |> Enum.flat_map(fn entry ->
      input = entry.input || %{}

      cond do
        is_binary(input["id"]) -> [input["id"]]
        is_list(input["ids"]) -> Enum.filter(input["ids"], &is_binary/1)
        true -> []
      end
    end)
    |> MapSet.new()
  end

  defp partition_record_mutations(tool_log) do
    created =
      tool_log
      |> Enum.filter(&(&1.name == "create_record" and not &1.error))
      |> Enum.flat_map(fn entry ->
        case Regex.run(~r/Created record: (.+)/, entry.result || "") do
          [_, id] -> [id]
          _ -> []
        end
      end)

    updated =
      tool_log
      |> Enum.filter(&(&1.name == "update_record" and not &1.error))
      |> Enum.flat_map(fn entry ->
        case Regex.run(~r/Updated record: (.+)/, entry.result || "") do
          [_, id] -> [id]
          _ -> []
        end
      end)

    {created, updated}
  end

  defp maybe_opt(opts, _key, nil), do: opts
  defp maybe_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp timestamp_id do
    DateTime.utc_now()
    |> DateTime.to_iso8601()
    |> String.replace(~r/[:\.]/, "-")
  end

  # Build a %Sandbox.Profile{} from the effective sandbox root (agent
  # first, then config). Returns `nil` if neither is set, in which case
  # tool spawn falls back to unsandboxed Port.open.
  defp build_sandbox_profile(nil, nil), do: nil

  defp build_sandbox_profile(agent_sandbox, config_sandbox) do
    root =
      (agent_sandbox || config_sandbox)
      |> Path.expand()

    Egghead.Sandbox.Profile.from_root(root, net: false)
  end

  @doc false
  # Enforces the "sandboxes only narrow" rule: an agent sandbox must be
  # a subpath of the config sandbox. Widening attempts get clamped to
  # the config ceiling with a loud warning — the agent keeps running but
  # can't slip its fence. Agents with no sandbox or no config sandbox
  # pass through unchanged (hoisting handles those cases elsewhere).
  def clamp_agent_sandbox(nil, _config, _agent_id), do: nil
  def clamp_agent_sandbox(agent, nil, _agent_id), do: agent

  def clamp_agent_sandbox(agent, config, agent_id) do
    agent_abs = Path.expand(agent)
    config_abs = Path.expand(config)

    if agent_abs == config_abs or String.starts_with?(agent_abs, config_abs <> "/") do
      agent
    else
      Logger.warning(
        "Agent #{agent_id}: declared `sandbox: #{agent}` is outside the config sandbox " <>
          "`#{config}`. Clamping to config ceiling — agent sandboxes can only narrow, never " <>
          "widen. Fix: change the agent record to declare a path inside #{config}, or remove " <>
          "the agent-level `sandbox:` key to inherit the config root."
      )

      config
    end
  end
end
