defmodule Egghead.Agent do
  @moduledoc """
  An agent process backed by a record of class `:agent`.

  The agent's record body is its disposition (system prompt). Its frontmatter
  meta fields configure the model, provider, capabilities, and LLM features.

  ## Agent Record Format

  ```markdown
  ---
  id: agents/scout
  class: agent
  model: claude-sonnet-4-6
  provider: anthropic
  capabilities: [record_read, record_append, search]
  thinking: enabled
  context_threshold: 0.75
  max_tokens: 4096
  temperature: 0.7
  ---

  You look for connections between records across different domains...
  ```

  ## Meta Fields

  - `model` — LLM model id (default: claude-sonnet-4-6)
  - `provider` — LLM provider (default: anthropic)
  - `capabilities` — what the agent can do: record_read, record_append, search
  - `thinking` — "enabled" or "adaptive" for extended thinking (if model supports it)
  - `context_threshold` — fraction of context window before auto-summarize (default: 0.75)
  - `max_tokens` — max response tokens per turn
  - `temperature` — sampling temperature

  ## Context Management

  Each agent tracks cumulative token usage per session. When the session
  approaches the context window limit (determined by querying the model's
  `max_input_tokens` via the Models API), the agent automatically:

  1. Summarizes the conversation into a `deliberation` record
  2. Links the deliberation to all records referenced in the conversation
  3. Clears the conversation history
  4. Continues with the deliberation record as context

  The records are the persistent memory. Conversations are ephemeral.
  """

  use GenServer

  require Logger

  alias Egghead.LLM.Registry

  @valid_capabilities ~w(record_read record_append record_modify search)
  @default_context_threshold 0.75

  @base_system_prompt """
  You are an agent in Egghead, a shared knowledge base. Records are Markdown
  (with YAML frontmatter) or org-mode files, each with an id, title, tags,
  links to other records, a class (durable, inbox, deliberation, agent), and
  a body. Records are linked with [[wikilinks]].

  Use your tools to search and read records — don't guess about what's in
  the store. Reference records by their id. Create records to persist
  valuable knowledge, using meaningful ids and linking to related records.

  Be concise and substantive.
  """

  @chat_addendum """
  You are in a shared chat room with other agents and a human. Address other
  agents with @agents/id syntax — only @-mentions trigger activation. If you
  have nothing substantive to add, respond with exactly [PASS] — nothing else,
  no addendum. Don't restate what others already said. Keep responses brief.
  """

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            disposition: String.t(),
            model: String.t(),
            provider: atom(),
            capabilities: [String.t()],
            thinking: String.t() | nil,
            max_tokens: non_neg_integer(),
            temperature: float() | nil,
            context_threshold: float(),
            context_window: non_neg_integer() | nil,
            history: [map()],
            usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()},
            session_tokens: non_neg_integer(),
            referenced_records: MapSet.t()
          }

    defstruct [
      :id,
      :name,
      :disposition,
      :model,
      :provider,
      :thinking,
      :temperature,
      capabilities: [],
      max_tokens: 4096,
      context_threshold: 0.75,
      context_window: nil,
      history: [],
      usage: %{input_tokens: 0, output_tokens: 0},
      session_tokens: 0,
      referenced_records: MapSet.new()
    ]
  end

  # --- Public API ---

  @doc """
  Starts an agent from a record.
  """
  @spec start_link(Egghead.Record.t()) :: GenServer.on_start()
  def start_link(record) do
    name = agent_name(record.id)
    GenServer.start_link(__MODULE__, record, name: name)
  end

  @doc """
  Sends a prompt to an agent and returns its response.

  Conversation history is maintained between prompts within the same session.
  When the context window fills up, the agent auto-summarizes to a deliberation
  record and starts a fresh session.
  """
  @spec prompt(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def prompt(agent_id, message, opts \\ []) do
    name = agent_name(agent_id)

    case GenServer.whereis(name) do
      nil -> {:error, :agent_not_found}
      _pid -> GenServer.call(name, {:prompt, message, opts}, 300_000)
    end
  end

  @doc """
  Manually triggers a handoff: summarizes the current conversation into a
  deliberation record, clears history, and optionally starts a new prompt.
  Returns `{:ok, deliberation_record_id}`.
  """
  @spec handoff(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def handoff(agent_id, next_prompt \\ nil) do
    name = agent_name(agent_id)

    case GenServer.whereis(name) do
      nil -> {:error, :agent_not_found}
      _pid -> GenServer.call(name, {:handoff, next_prompt}, 300_000)
    end
  end

  @doc """
  Saves key insights from the current conversation to durable records
  without clearing the session.
  """
  @spec save(String.t()) :: {:ok, String.t()} | {:error, term()}
  def save(agent_id) do
    name = agent_name(agent_id)

    case GenServer.whereis(name) do
      nil -> {:error, :agent_not_found}
      _pid -> GenServer.call(name, :save, 300_000)
    end
  end

  @doc """
  Clears an agent's conversation history.
  """
  @spec clear_history(String.t()) :: :ok | {:error, :agent_not_found}
  def clear_history(agent_id) do
    name = agent_name(agent_id)

    case GenServer.whereis(name) do
      nil -> {:error, :agent_not_found}
      _pid -> GenServer.call(name, :clear_history)
    end
  end

  @doc """
  Returns an agent's token usage and context info.
  """
  @spec usage(String.t()) :: {:ok, map()} | {:error, :agent_not_found}
  def usage(agent_id) do
    name = agent_name(agent_id)

    case GenServer.whereis(name) do
      nil ->
        {:error, :agent_not_found}

      _pid ->
        GenServer.call(name, :usage)
    end
  end

  @doc """
  Lists all running agents.
  """
  @spec list_agents() :: [map()]
  def list_agents do
    # Get agent records from the store
    store_agents =
      Egghead.search_by_class(:agent)
      |> Enum.map(& &1.id)

    # Include the default agent
    all_ids = Enum.uniq(["egghead" | store_agents])

    all_ids
    |> Enum.filter(fn id -> agent_name(id) |> GenServer.whereis() != nil end)
    |> Enum.map(fn id ->
      name = agent_name(id)
      state = :sys.get_state(GenServer.whereis(name))

      %{
        id: state.id,
        name: state.name,
        capabilities: state.capabilities,
        model: state.model,
        usage: state.usage,
        session_tokens: state.session_tokens,
        context_window: state.context_window,
        history_length: length(state.history)
      }
    end)
  end

  @doc """
  Returns the registered name for an agent process.
  """
  @spec agent_name(String.t()) :: atom()
  def agent_name(id) do
    :"egghead_agent_#{id}"
  end

  # --- GenServer callbacks ---

  @impl true
  def init(record) do
    capabilities = parse_capabilities(record)
    thinking = get_meta_string(record, "thinking", nil)
    max_tokens = get_meta_int(record, "max_tokens", 4096)
    temperature = get_meta_float(record, "temperature", nil)

    context_threshold =
      get_meta_float(record, "context_threshold", @default_context_threshold)

    # Resolve model via registry — supports "provider/model" or bare model names
    # Falls back to old "model" + "provider" fields for backwards compat
    raw_model = get_meta_string(record, "model", nil)
    fallback_provider = get_meta_string(record, "provider", nil)

    model =
      cond do
        raw_model && String.contains?(raw_model, "/") ->
          raw_model

        raw_model && fallback_provider ->
          "#{fallback_provider}/#{raw_model}"

        raw_model ->
          raw_model

        true ->
          try do
            Registry.default_model()
          catch
            :exit, _ -> "anthropic/claude-sonnet-4-6"
          end
      end

    state = %State{
      id: record.id,
      name: record.title || record.id,
      disposition: record.body || "",
      model: model,
      provider: nil,
      capabilities: capabilities,
      thinking: thinking,
      max_tokens: max_tokens,
      temperature: temperature,
      context_threshold: context_threshold
    }

    Logger.info(
      "Agent started: #{state.name} (#{state.id}) model=#{model} capabilities=#{inspect(capabilities)}"
    )

    # Fetch model info asynchronously
    send(self(), :fetch_model_info)

    {:ok, state}
  end

  @impl true
  def handle_call({:prompt, message, opts}, _from, state) do
    # Check if we need to auto-summarize before processing
    state =
      if should_summarize?(state) do
        case do_summarize_to_deliberation(state) do
          {:ok, _delib_id, new_state} -> new_state
          {:error, _, state} -> state
        end
      else
        state
      end

    {result, state} = do_prompt(state, message, opts)
    {:reply, result, state}
  end

  def handle_call({:handoff, next_prompt}, _from, state) do
    case do_summarize_to_deliberation(state) do
      {:ok, delib_id, state} ->
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
        if(state.context_window,
          do: Float.round(state.session_tokens / state.context_window * 100, 1),
          else: nil
        ),
      history_turns: length(state.history),
      referenced_records: MapSet.to_list(state.referenced_records)
    }

    {:reply, {:ok, info}, state}
  end

  @impl true
  def handle_info(:fetch_model_info, state) do
    context_window =
      try do
        case Registry.get_model_info(state.model) do
          {:ok, %{"max_input_tokens" => max_input}} when is_integer(max_input) ->
            Logger.info(
              "Agent #{state.name}: model #{state.model} context window = #{max_input} tokens"
            )

            max_input

          {:error, reason} ->
            Logger.warning("Agent #{state.name}: could not fetch model info: #{inspect(reason)}")
            fallback_context_window(state.model)
        end
      catch
        :exit, _ ->
          Logger.warning("Agent #{state.name}: LLM Registry not available")
          fallback_context_window(state.model)
      end

    {:noreply, %{state | context_window: context_window}}
  end

  # --- Prompt execution (agentic tool-use loop) ---

  @max_tool_rounds 20

  defp do_prompt(state, message, opts) do
    room = Keyword.get(opts, :room)
    system_prompt = build_system_prompt(state, room)

    # Compact old tool results before adding new message
    compacted = compact_history(state.history)

    # Append user message to compacted history
    history = compacted ++ [%{role: "user", content: message}]

    # Get tools for this agent's capabilities
    tools = Egghead.Agent.Tools.definitions_for(state.capabilities)

    llm_opts =
      [
        model: state.model,
        system: system_prompt,
        max_tokens: state.max_tokens
      ]
      |> maybe_opt(:temperature, state.temperature)
      |> maybe_opt(:thinking, state.thinking)
      |> maybe_opt(:tools, if(tools != [], do: tools))
      |> Keyword.merge(Keyword.take(opts, [:max_tokens, :temperature, :api_key]))

    # Streaming callback (optional)
    llm_opts =
      case Keyword.get(opts, :on_chunk) do
        nil -> llm_opts
        cb -> Keyword.put(llm_opts, :on_chunk, cb)
      end

    start_time = System.monotonic_time(:millisecond)

    # Run the agentic loop: call LLM, execute tool uses, feed results back
    case agent_loop(state, history, llm_opts, 0) do
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
          agent_id: state.id,
          model: state.model,
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

  # The agentic loop: call LLM, if it wants tools, execute them and call again.
  # Returns {:ok, text, history, usage, tool_log} or {:error, reason}.
  # tool_log is a list of %{name, input, result, error} maps.
  defp agent_loop(_state, _history, _opts, round) when round >= @max_tool_rounds do
    {:error, :max_tool_rounds_exceeded}
  end

  defp agent_loop(state, history, opts, round) do
    case call_llm(state.model, history, opts) do
      {:ok, %{content: content, stop_reason: stop_reason, usage: usage}} ->
        input_tokens = usage[:input_tokens] || 0
        output_tokens = usage[:output_tokens] || 0
        acc_usage = %{input_tokens: input_tokens, output_tokens: output_tokens}

        if stop_reason == "tool_use" do
          tool_uses = Enum.filter(content, &(&1["type"] == "tool_use"))

          # Execute each tool, build log entries
          {tool_results, tool_log} =
            Enum.map(tool_uses, fn tool_use ->
              Logger.info(
                "Agent #{state.name} calling tool: #{tool_use["name"]}(#{inspect(tool_use["input"])})"
              )

              {status, result_text} =
                case Egghead.Agent.Tools.execute(tool_use["name"], tool_use["input"], %{
                       agent_id: state.id
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

          case agent_loop(state, history, opts, round + 1) do
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
      # Ask the agent to summarize through its own disposition lens
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
        model: state.model,
        system: build_system_prompt(state),
        max_tokens: state.max_tokens
      ]

      case call_llm(state.model, messages, llm_opts) do
        {:ok, %{content: content}} ->
          summary =
            content
            |> Enum.filter(&(&1["type"] == "text"))
            |> Enum.map_join("\n", & &1["text"])

          delib_id = "deliberation/#{state.id}/#{timestamp_id()}"
          ref_ids = MapSet.to_list(state.referenced_records)

          attrs = %{
            "id" => delib_id,
            "title" => "Deliberation: #{state.name} — #{Date.utc_today()}",
            "tags" => ["deliberation", "agent:#{state.id}"],
            "links" => ref_ids,
            "class" => "deliberation",
            "author" => state.id,
            "body" => summary
          }

          case Egghead.create_record(attrs) do
            {:ok, _record} ->
              Logger.info("Agent #{state.name} created deliberation: #{delib_id}")

            {:error, reason} ->
              Logger.warning("Agent #{state.name} deliberation failed: #{inspect(reason)}")
          end

          # Clear history, keep the deliberation as future context
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
        model: state.model,
        system: build_system_prompt(state),
        max_tokens: state.max_tokens
      ]

      # Give the agent its tools so it can create_record
      tools = Egghead.Agent.Tools.definitions_for(state.capabilities)
      llm_opts = maybe_opt(llm_opts, :tools, if(tools != [], do: tools))

      case agent_loop(state, messages, llm_opts, 0) do
        {:ok, response, _history, _usage, _refs} ->
          {{:ok, response}, state}

        {:error, _} = error ->
          {error, state}
      end
    end
  end

  # --- System prompt ---

  defp build_system_prompt(state, room \\ nil) do
    context_status = format_context_status(state)

    base = """
    #{@base_system_prompt}

    You are **#{state.name}** (#{state.id}). #{context_status}

    #{state.disposition}
    """

    if room do
      agents_list = room.agents |> Enum.join(", ")

      # Only include new messages since agent's last response (diff)
      transcript = format_room_diff(room, state.id)

      base <>
        @chat_addendum <>
        """

        Room: #{room.id} | Agents: #{agents_list}

        #{transcript}
        """
    else
      base
    end
  end

  # --- LLM dispatch ---

  # Compact old tool results in history. Keeps the last turn's tool results
  # intact (the agent may still be reasoning about them). Earlier tool results
  # are replaced with a brief summary showing what was fetched and how large it was.
  defp compact_history(history) do
    # Find where the last complete turn starts (last user message that isn't tool results)
    last_turn_start =
      history
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {entry, idx} ->
        case entry do
          %{role: "user", content: content} when is_binary(content) -> idx
          _ -> nil
        end
      end) || 0

    history
    |> Enum.with_index()
    |> Enum.map(fn {entry, idx} ->
      if idx < last_turn_start do
        compact_entry(entry)
      else
        entry
      end
    end)
  end

  defp compact_entry(%{role: "user", content: content} = entry) when is_list(content) do
    # Tool results — compact them
    compacted =
      Enum.map(content, fn
        %{type: "tool_result", content: result_text} = result when is_binary(result_text) ->
          if String.length(result_text) > 200 do
            token_est = div(String.length(result_text), 4)
            preview = String.slice(result_text, 0, 100)
            %{result | content: "[Compacted ~#{token_est}tok] #{preview}..."}
          else
            result
          end

        other ->
          other
      end)

    %{entry | content: compacted}
  end

  defp compact_entry(entry), do: entry

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

    # Find the last message from this agent
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
          # First activation — show last 10 messages as catch-up
          Enum.take(transcript, -10)

        idx ->
          # Messages since our last response
          since_idx = length(transcript) - idx
          diff = Enum.drop(transcript, since_idx)

          # Always include at least the last 5 messages so the agent
          # has context even if re-activated immediately after speaking
          if length(diff) < 3 do
            Enum.take(transcript, -5)
          else
            diff
          end
      end

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

        # Truncate long messages in the transcript view
        content =
          if String.length(m.content) > 500 do
            String.slice(m.content, 0, 500) <> "..."
          else
            m.content
          end

        "#{label} #{content}"
      end)
    end
  end

  defp call_llm(model_str, messages, opts) do
    result =
      try do
        Registry.resolve(model_str)
      catch
        :exit, _ -> {:error, :registry_unavailable}
      end

    case result do
      {:ok, {module, provider_opts}} ->
        # Provider opts (resolved model name, api_key) take precedence over agent opts
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

  # --- Tool log helpers ---

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

  # --- Helpers ---

  defp parse_capabilities(record) do
    raw =
      case record.meta["capabilities"] do
        list when is_list(list) -> Enum.map(list, &to_string/1)
        str when is_binary(str) -> String.split(str, ~r/[,\s]+/, trim: true)
        _ -> ["record_read", "search"]
      end

    Enum.filter(raw, &(&1 in @valid_capabilities))
  end

  defp get_meta_string(record, key, default) do
    case record.meta[key] do
      nil -> default
      val -> to_string(val)
    end
  end

  defp get_meta_int(record, key, default) do
    case record.meta[key] do
      nil -> default
      val when is_integer(val) -> val
      val -> String.to_integer(to_string(val))
    end
  rescue
    _ -> default
  end

  defp get_meta_float(record, key, default) do
    case record.meta[key] do
      nil -> default
      val when is_float(val) -> val
      val when is_integer(val) -> val / 1
      val -> String.to_float(to_string(val))
    end
  rescue
    _ -> default
  end

  defp maybe_opt(opts, _key, nil), do: opts
  defp maybe_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp timestamp_id do
    DateTime.utc_now()
    |> DateTime.to_iso8601()
    |> String.replace(~r/[:\.]/, "-")
  end

  defp fallback_context_window(model) do
    cond do
      String.contains?(model, "opus") -> 1_000_000
      String.contains?(model, "haiku") -> 200_000
      true -> 200_000
    end
  end
end
