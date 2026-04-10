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

  @base_system_prompt_intro """
  You are an agent in Egghead, a shared knowledge base. Records are Markdown
  (with YAML frontmatter) or org-mode files, each with an id, title, tags,
  links to other records, a class (durable, inbox, deliberation, agent), and
  a body. Records are linked with [[wikilinks]]. When you reference a record
  in your response, always use [[wikilink]] syntax (e.g. [[design/egghead-overview]]).
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

  @base_system_prompt_outro """

  Be concise and substantive.
  """

  @chat_addendum """
  You are in a shared chat room with other agents and a human.

  BEFORE doing anything else — before calling any tools — read the transcript
  above. If another agent already answered the question, default to [PASS]
  unless you can do ONE of these:
  - Surface records or information they did not mention
  - Correct a factual error in their response
  - Offer analysis or synthesis they did not provide (not a restatement)

  If none of those apply, [PASS].

  [PASS] rules:
  - [PASS] must be your complete response. Nothing before or after it.
  - If you are not sure whether you have something new to add, [PASS].
  - Do not search for records another agent already found.
  - Do not summarize or acknowledge what other agents said.

  If you DO respond:
  - Only add information NOT already in the transcript.
  - Do not restate what other agents said. Build on it or correct it.
  - Address other agents with @id to trigger their activation.
  - Keep responses brief.
  - In the transcript, your messages appear under your agent id. Speak as
    yourself — use "I" not your own name in third person.
  """

  defmodule State do
    @moduledoc false

    defstruct [
      :agent_id,
      :room_id,
      :identity,
      history: [],
      usage: %{input_tokens: 0, output_tokens: 0},
      session_tokens: 0,
      context_window: nil,
      context_threshold: 0.70,
      referenced_records: MapSet.new()
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

  @spec clear_history(pid() | atom()) :: :ok
  def clear_history(session) do
    GenServer.call(session, :clear_history)
  end

  @spec usage(pid() | atom()) :: {:ok, map()}
  def usage(session) do
    GenServer.call(session, :usage)
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

    state = %State{
      agent_id: agent_id,
      room_id: room_id,
      identity: identity,
      context_window: identity[:context_window],
      context_threshold: identity[:context_threshold] || 0.70
    }

    Logger.debug("Session started: #{agent_id} in #{room_id || "default"}")

    {:ok, state}
  end

  @impl true
  def handle_call({:prompt, message, opts}, _from, state) do
    room = Keyword.get(opts, :room)

    state =
      if should_summarize?(state) do
        case do_summarize_to_deliberation(state) do
          {:ok, delib_id, new_state} ->
            if room, do: broadcast_handoff(room.id, state.agent_id, delib_id)
            new_state

          {:error, _, state} ->
            state
        end
      else
        state
      end

    {result, state} = do_prompt(state, message, opts)
    {:reply, result, state}
  end

  def handle_call({:handoff, opts}, _from, state) do
    room_id = Keyword.get(opts, :room_id, state.room_id)
    next_prompt = Keyword.get(opts, :next_prompt)

    case do_summarize_to_deliberation(state) do
      {:ok, delib_id, state} ->
        if room_id, do: broadcast_handoff(room_id, state.agent_id, delib_id)

        if next_prompt do
          {result, state} = do_prompt(state, next_prompt, [])
          {:reply, {:ok, delib_id, result}, state}
        else
          {:reply, {:ok, delib_id}, state}
        end

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:save, _from, state) do
    {result, state} = do_save(state)
    {:reply, result, state}
  end

  def handle_call(:clear_history, _from, state) do
    {:reply, :ok, %{state | history: [], session_tokens: 0, referenced_records: MapSet.new()}}
  end

  def handle_call(:usage, _from, state) do
    info = %{
      total_usage: state.usage,
      session_tokens: state.session_tokens,
      context_window: state.context_window,
      context_used_pct:
        if(state.context_window && state.context_window > 0,
          do: Float.round(state.session_tokens / state.context_window * 100, 1),
          else: nil
        ),
      history_turns: length(state.history),
      referenced_records: MapSet.to_list(state.referenced_records)
    }

    {:reply, {:ok, info}, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    Logger.debug("Session #{state.agent_id}/#{state.room_id}: room process died, stopping")
    {:stop, :normal, state}
  end

  # --- Prompt execution ---

  defp do_prompt(state, message, opts) do
    id = state.identity
    room = Keyword.get(opts, :room)
    system_prompt = build_system_prompt(state, room)

    compacted = compact_history(state.history)
    history = compacted ++ [%{role: "user", content: message}]

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
    room_id = if room, do: room.id, else: state.room_id

    case agent_loop(state, history, llm_opts, room_id, 0) do
      {:ok, final_text, history, total_usage, tool_log} ->
        duration = System.monotonic_time(:millisecond) - start_time

        {created, updated} = partition_record_mutations(tool_log)
        refs = extract_refs_from_tool_log(tool_log)

        state = %{
          state
          | history: history,
            usage: %{
              input_tokens: state.usage.input_tokens + total_usage.input_tokens,
              output_tokens: state.usage.output_tokens + total_usage.output_tokens
            },
            session_tokens:
              state.session_tokens + total_usage.input_tokens + total_usage.output_tokens,
            referenced_records: MapSet.union(state.referenced_records, refs)
        }

        context_pct =
          if state.context_window && state.context_window > 0,
            do: Float.round(state.session_tokens / state.context_window * 100, 1),
            else: nil

        response = %Egghead.Agent.Response{
          text: final_text,
          agent_id: state.agent_id,
          model: id[:model],
          usage:
            Map.merge(total_usage, %{
              session_tokens: state.session_tokens,
              context_window: state.context_window,
              context_pct: context_pct
            }),
          tool_calls: tool_log,
          records_created: created,
          records_updated: updated,
          duration_ms: duration
        }

        {{:ok, response}, state}

      {:error, _} = error ->
        {error, state}
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
        acc_usage = %{input_tokens: input_tokens, output_tokens: output_tokens}

        if stop_reason == "tool_use" do
          tool_uses = Enum.filter(content, &(&1["type"] == "tool_use"))

          {tool_results, tool_log} =
            Enum.map(tool_uses, fn tool_use ->
              Logger.info(
                "Agent #{state.identity[:name]} calling tool: #{tool_use["name"]}(#{inspect(tool_use["input"])})"
              )

              {status, result_text} =
                case Egghead.Agent.Tools.execute(tool_use["name"], tool_use["input"], %{
                       agent_id: state.agent_id,
                       room_id: room_id
                     }) do
                  {:ok, text} -> {:ok, text}
                  {:error, text} -> {:error, text}
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
            end)
            |> Enum.unzip()

          history =
            history ++
              [
                %{role: "assistant", content: content},
                %{role: "user", content: tool_results}
              ]

          case agent_loop(state, history, opts, room_id, round + 1) do
            {:ok, text, history, more_usage, more_log} ->
              merged_usage = %{
                input_tokens: acc_usage.input_tokens + more_usage.input_tokens,
                output_tokens: acc_usage.output_tokens + more_usage.output_tokens
              }

              {:ok, text, history, merged_usage, tool_log ++ more_log}

            error ->
              error
          end
        else
          text =
            content
            |> Enum.filter(&(&1["type"] == "text"))
            |> Enum.map_join("\n", & &1["text"])

          history = history ++ [%{role: "assistant", content: content}]

          {:ok, text, history, acc_usage, []}
        end

      {:error, _} = error ->
        error
    end
  end

  # --- Context management ---

  defp should_summarize?(%{context_window: nil}), do: false

  defp should_summarize?(state) do
    state.context_window != nil and
      state.session_tokens > state.context_window * state.context_threshold and
      length(state.history) > 0
  end

  defp do_summarize_to_deliberation(state) do
    if state.history == [] do
      {:error, :no_history, state}
    else
      id = state.identity

      summary_prompt = """
      Summarize this conversation for your own future reference. Include:
      - Key topics discussed and conclusions reached
      - Open questions or unresolved threads
      - Record ids that were important to the discussion
      - Any decisions or insights worth preserving

      Be thorough but concise. This summary will be stored as a deliberation
      record and used as context for future conversations.
      """

      messages = state.history ++ [%{role: "user", content: summary_prompt}]

      llm_opts = [
        model: id[:model],
        system: build_system_prompt(state),
        max_tokens: id[:max_tokens] || 4096
      ]

      case call_llm(id[:model], messages, llm_opts) do
        {:ok, %{content: content}} ->
          summary =
            content
            |> Enum.filter(&(&1["type"] == "text"))
            |> Enum.map_join("\n", & &1["text"])

          delib_id = "deliberation/#{state.agent_id}/#{timestamp_id()}"
          ref_ids = MapSet.to_list(state.referenced_records)

          attrs = %{
            "id" => delib_id,
            "title" => "Deliberation: #{id[:name]} — #{Date.utc_today()}",
            "tags" =>
              ["deliberation", "agent:#{state.agent_id}"] ++
                if(state.room_id, do: ["room:#{state.room_id}"], else: []),
            "links" => ref_ids,
            "class" => "deliberation",
            "author" => state.agent_id,
            "body" => summary
          }

          case Egghead.create_record(attrs) do
            {:ok, _record} ->
              Logger.info("Agent #{id[:name]} created deliberation: #{delib_id}")

            {:error, reason} ->
              Logger.warning("Agent #{id[:name]} deliberation failed: #{inspect(reason)}")
          end

          new_state = %{
            state
            | history: [],
              session_tokens: 0,
              referenced_records: MapSet.new([delib_id])
          }

          {:ok, delib_id, new_state}

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end

  defp do_save(state) do
    if state.history == [] do
      {{:error, :no_history}, state}
    else
      id = state.identity

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

      messages = state.history ++ [%{role: "user", content: save_prompt}]

      llm_opts = [
        model: id[:model],
        system: build_system_prompt(state),
        max_tokens: id[:max_tokens] || 4096
      ]

      tools = Egghead.Agent.Tools.definitions_for(id[:capabilities] || [])
      llm_opts = maybe_opt(llm_opts, :tools, if(tools != [], do: tools))

      case agent_loop(state, messages, llm_opts, nil, 0) do
        {:ok, response, _history, _usage, _refs} ->
          {{:ok, response}, state}

        {:error, _} = error ->
          {error, state}
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
        @base_system_prompt_intro <> @base_system_prompt_outro
      end

    base = """
    #{intro}

    You are **#{id[:name]}** (#{id[:id]}). #{context_status}

    #{id[:disposition]}
    """

    if room do
      agents_list = room.agents |> Enum.join(", ")
      transcript = format_room_diff(room, state.agent_id)

      # On first activation in a room, include the most recent deliberation
      # for this room so the agent has structured context, not just 5 messages.
      prior_context = if state.history == [], do: room_deliberation_context(room.id)

      base <>
        @chat_addendum <>
        """

        Room: #{room.id} | Agents: #{agents_list}
        """ <>
        if(prior_context, do: "\n#{prior_context}\n", else: "") <>
        """

        #{transcript}
        """
    else
      base
    end
  end

  # Find the most recent deliberation record tagged with this room.
  # Returns a brief context block or nil.
  defp room_deliberation_context(room_id) do
    case Egghead.search_by_tag("room:#{room_id}") do
      [] ->
        nil

      records ->
        latest = Enum.max_by(records, & &1.updated)

        case Egghead.get_record(latest.id) do
          {:ok, record} ->
            body = record.body || ""

            preview =
              if String.length(body) > 500 do
                String.slice(body, 0, 500) <> "..."
              else
                body
              end

            "Prior context (from #{latest.id}):\n#{preview}"

          _ ->
            nil
        end
    end
  end

  # --- Compaction ---

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
    case {state.session_tokens, state.context_window} do
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

  defp format_room_diff(room, agent_id) do
    transcript = room.transcript || []

    last_own_idx =
      transcript
      |> Enum.reverse()
      |> Enum.find_index(fn m ->
        case m.sender do
          %{id: ^agent_id} -> true
          _ -> false
        end
      end)

    messages =
      case last_own_idx do
        nil ->
          Enum.take(transcript, -5)

        idx ->
          since_idx = length(transcript) - idx
          diff = Enum.drop(transcript, since_idx)

          if length(diff) < 3 do
            Enum.take(transcript, -5)
          else
            diff
          end
      end

    # Drop the agent's own past messages — they are already present in
    # state.history as assistant turns. Including them here too caused
    # the LLM to see its own outputs twice and (in extreme cases) parrot
    # them back concatenated. The transcript section is meant to be
    # "what others said".
    messages = Enum.reject(messages, &own_message?(&1, agent_id))

    if messages == [] do
      "(no new messages)"
    else
      messages
      |> Enum.map_join("\n", fn m ->
        label =
          case m.sender do
            %{type: :user, name: name} -> "[#{name}]"
            %{type: :agent, id: id} -> "[#{id}]"
            _ -> "[unknown]"
          end

        content =
          if String.length(m.content) > 300 do
            String.slice(m.content, 0, 300) <> "..."
          else
            m.content
          end

        "#{label} #{content}"
      end)
    end
  end

  defp own_message?(%{sender: %{id: id}}, agent_id), do: id == agent_id
  defp own_message?(_, _), do: false

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
           "Set the appropriate API key or add it to ~/.egghead/providers.yml. " <>
           "Check the model field in the agent record."}

      {:error, :registry_unavailable} ->
        {:error,
         "No LLM provider available. Set ANTHROPIC_API_KEY, OPENAI_API_KEY, or " <>
           "GOOGLE_API_KEY, or create ~/.egghead/providers.yml"}

      {:error, :missing_api_key} ->
        {:error,
         "API key not set for this provider. Set the appropriate environment variable " <>
           "or add it to ~/.egghead/providers.yml"}

      {:error, reason} ->
        {:error, {:provider_error, reason}}
    end
  end

  # --- Helpers ---

  defp broadcast_handoff(room_id, agent_id, delib_id) do
    Phoenix.PubSub.broadcast(
      Egghead.PubSub,
      Egghead.Chat.Room.topic(room_id),
      {:agent_handoff, room_id, agent_id, delib_id}
    )
  end

  defp extract_refs_from_tool_log(tool_log) do
    tool_log
    |> Enum.flat_map(fn entry ->
      result = entry.result || ""

      ~r/(?:^- |^id: )([a-zA-Z0-9_\-\/]+)/m
      |> Regex.scan(result)
      |> Enum.map(fn [_, id] -> id end)
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
end
