defmodule Egghead.Chat.Coordinator do
  @moduledoc """
  The Coordinator manages relevance-gated activation for chat rooms.

  It subscribes to room events and decides which agents should activate
  in response. The Coordinator is implemented as part of the default
  "egghead" agent — it has a special `coordinate` capability and an
  `activate_agents` tool.

  ## Activation flow

  1. Human sends message to room → PubSub broadcast
  2. Coordinator receives the broadcast
  3. Tier 1 (structural filter, zero tokens): @-mentions, @everyone, graph proximity
  4. Tier 2 (if ambiguous): lightweight LLM decides which agents should speak
  5. Selected agents are prompted with the room transcript as context

  ## Graph topology

  The Coordinator gates activation, not communication. Once activated,
  agents read from and write to the Room directly. The Coordinator
  never relays messages between agents.
  """

  use GenServer

  require Logger

  alias Egghead.Chat.Room

  @pubsub Egghead.PubSub

  defmodule AgentInfo do
    @moduledoc false
    defstruct [:id, :name, :capabilities, :tags, :disposition]
  end

  defmodule State do
    @moduledoc false
    defstruct agents: %{}, rooms: MapSet.new(), handoffs_in_progress: MapSet.new(), corpus: %{}
  end

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register an agent with the coordinator so it can be considered for activation.
  """
  @spec register_agent(GenServer.server(), String.t(), map()) :: :ok
  def register_agent(server \\ __MODULE__, agent_id, metadata) do
    GenServer.cast(server, {:register_agent, agent_id, metadata})
  end

  @doc """
  Unregister an agent.
  """
  @spec unregister_agent(GenServer.server(), String.t()) :: :ok
  def unregister_agent(server \\ __MODULE__, agent_id) do
    GenServer.cast(server, {:unregister_agent, agent_id})
  end

  @doc """
  Subscribe the coordinator to a room's events.
  """
  @spec watch_room(GenServer.server(), String.t()) :: :ok
  def watch_room(server \\ __MODULE__, room_id) do
    GenServer.cast(server, {:watch_room, room_id})
  end

  @doc """
  Get the list of registered agents.
  """
  @spec list_registered(GenServer.server()) :: [map()]
  def list_registered(server \\ __MODULE__) do
    GenServer.call(server, :list_registered)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    # Subscribe to agent lifecycle events so we can announce
    # restarts and terminations into the rooms we're watching.
    Phoenix.PubSub.subscribe(@pubsub, Egghead.Agent.lifecycle_topic())

    {:ok, %State{}}
  end

  @impl true
  def handle_cast({:register_agent, agent_id, metadata}, state) do
    info = %AgentInfo{
      id: agent_id,
      name: metadata[:name] || agent_id,
      capabilities: metadata[:capabilities] || [],
      tags: metadata[:tags] || [],
      disposition: metadata[:disposition] || ""
    }

    agents = Map.put(state.agents, agent_id, info)
    corpus = Egghead.Chat.Relevance.build_corpus(agents)
    state = %{state | agents: agents, corpus: corpus}
    Logger.debug("Coordinator: registered agent #{agent_id}")
    {:noreply, state}
  end

  def handle_cast({:unregister_agent, agent_id}, state) do
    agents = Map.delete(state.agents, agent_id)
    corpus = Egghead.Chat.Relevance.build_corpus(agents)
    state = %{state | agents: agents, corpus: corpus}
    Logger.debug("Coordinator: unregistered agent #{agent_id}")
    {:noreply, state}
  end

  def handle_cast({:watch_room, room_id}, state) do
    Phoenix.PubSub.subscribe(@pubsub, Room.topic(room_id))
    state = %{state | rooms: MapSet.put(state.rooms, room_id)}
    Logger.info("Coordinator: watching room #{room_id}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:list_registered, _from, state) do
    agents =
      state.agents
      |> Map.values()
      |> Enum.map(fn info ->
        %{id: info.id, name: info.name, capabilities: info.capabilities}
      end)

    {:reply, agents, state}
  end

  # --- Room event handling ---

  @impl true
  def handle_info({:user_message, msg}, state) do
    room_id = msg.room_id || state.rooms |> MapSet.to_list() |> List.first()

    if room_id do
      agents_to_activate = tier1_filter(msg, state.agents)

      if agents_to_activate == [] do
        Logger.warning("Coordinator: no agents registered, nobody to activate")
      end

      activate(agents_to_activate, msg, room_id, state)
    else
      Logger.warning("Coordinator: received message but not watching any rooms")
    end

    {:noreply, state}
  end

  def handle_info({:agent_mentions, room_id, from_agent, mentioned_ids}, state) do
    agents =
      mentioned_ids
      |> Enum.flat_map(fn id -> find_agent(state.agents, id) end)

    if agents != [] do
      Logger.info("Coordinator: #{from_agent} mentioned #{Enum.map_join(agents, ", ", & &1.id)}")

      broadcast_activation(room_id, length(agents))

      Enum.each(agents, fn agent_info ->
        Task.start(fn ->
          prompt_agent_in_room(agent_info.id, room_id, "(You were @-mentioned by #{from_agent})")
        end)
      end)
    end

    {:noreply, state}
  end

  def handle_info({:agent_message, msg}, state) do
    # Agent spoke — clear any handoff-in-progress flag for this agent
    state = %{
      state
      | handoffs_in_progress:
          MapSet.delete(state.handoffs_in_progress, {msg.sender.id, msg.room_id})
    }

    {:noreply, state}
  end

  def handle_info(:budget_exhausted, state) do
    Logger.debug("Coordinator: turn budget exhausted, waiting for human")
    {:noreply, state}
  end

  def handle_info(:continued, state) do
    Logger.debug("Coordinator: human granted more turns")
    {:noreply, state}
  end

  def handle_info({:agent_joined, agent_id}, state) do
    Logger.debug("Coordinator: #{agent_id} joined room")
    {:noreply, state}
  end

  def handle_info({:agent_left, agent_id}, state) do
    Logger.debug("Coordinator: #{agent_id} left room")
    {:noreply, state}
  end

  def handle_info({:agents_activated, _count}, state), do: {:noreply, state}
  def handle_info({:agent_passed, _agent_id}, state), do: {:noreply, state}
  def handle_info({:agent_streaming, _, _, _}, state), do: {:noreply, state}
  def handle_info({:agent_tool_call, _, _, _, _}, state), do: {:noreply, state}
  def handle_info({:agent_tool_denied, _, _, _, _, _}, state), do: {:noreply, state}
  def handle_info({:agent_tool_output, _, _, _, _, _}, state), do: {:noreply, state}

  def handle_info({:agent_lifecycle, event, agent_id, reason}, state) do
    # Translate global agent lifecycle events into per-room system
    # notices so users see when an agent restarts or exits. We use
    # the agent's display name from the registered metadata when
    # available; otherwise the bare id.
    display =
      case Map.get(state.agents, agent_id) do
        %AgentInfo{name: name} -> name
        _ -> agent_id
      end

    text =
      case {event, reason} do
        {:started, _} ->
          "#{display} joined"

        {:terminated, :normal} ->
          "#{display} left"

        {:terminated, :shutdown} ->
          "#{display} left"

        {:terminated, {:shutdown, _}} ->
          "#{display} left"

        {:terminated, reason} ->
          "#{display} crashed: #{format_lifecycle_reason(reason)}"
      end

    for room_id <- state.rooms do
      Phoenix.PubSub.broadcast(@pubsub, Room.topic(room_id), {:system_notice, text})
    end

    {:noreply, state}
  end

  def handle_info({:agent_handoff_started, room_id, agent_id}, state) do
    # Mark the agent as in-handoff at the START of summarisation so
    # we don't activate it during the 30-60s LLM summary window.
    # Cleared on `:agent_handoff` (complete) below — at which point
    # the agent has fresh context and is ready to respond again.
    state = %{
      state
      | handoffs_in_progress: MapSet.put(state.handoffs_in_progress, {agent_id, room_id})
    }

    {:noreply, state}
  end

  def handle_info({:agent_handoff, room_id, agent_id, _delib_id}, state) do
    # Handoff complete — the agent's history was summarised into the
    # deliberation record and cleared. Remove the in-progress marker
    # so the agent can be activated for the next user message.
    state = %{
      state
      | handoffs_in_progress: MapSet.delete(state.handoffs_in_progress, {agent_id, room_id})
    }

    {:noreply, state}
  end

  # --- Tier 1: Structural filter (zero tokens) ---

  defp tier1_filter(msg, agents) do
    mentions = msg.mentions || []

    cond do
      # @everyone or @channel → huddle (serial, must respond) — includes Index
      # @jam → cacophony (parallel, low threshold) — includes Index
      broadcast_mention?(mentions) ->
        Map.values(agents)

      # @specific-agent → activate just that agent
      mentions != [] ->
        mentions
        |> Enum.flat_map(fn name ->
          find_agent(agents, name)
        end)

      # Open message (no @-mention) → activate all specialists
      # Index is infrastructure — excluded when specialists are available
      # TF-IDF scoring in activate/4 determines activation order
      true ->
        specialists = agents |> Map.values() |> Enum.reject(&(&1.id == "index"))
        if specialists != [], do: specialists, else: Map.values(agents)
    end
  end

  # Mentions that trigger room-wide activation (all agents including Index).
  defp broadcast_mention?(mentions) do
    Enum.any?(mentions, &(&1 in ["everyone", "channel", "jam"]))
  end

  defp direct_mention?(mentions) do
    mentions != [] and not Enum.any?(mentions, &(&1 in ["everyone", "channel", "jam"]))
  end

  # Which activation mode should we use for this message?
  #
  # - `:huddle` — `@everyone` / `@channel`: serial, every agent must respond
  #   (no `/pass`), each sees prior peers' output.
  # - `:jam`    — `@jam`: parallel, low participation threshold (speak up even
  #   with partial thoughts). Does not see peer output in-flight.
  # - `:normal` — anything else: respects the room's `:mode` (`:serial` by
  #   default, `:staggered` as opt-in). Strict `/pass` semantics.
  defp activation_mode(mentions) do
    cond do
      "jam" in mentions -> :jam
      "everyone" in mentions or "channel" in mentions -> :huddle
      true -> :normal
    end
  end

  defp find_agent(agents, name) do
    lower_name = String.downcase(name)

    # Try exact match first, then fuzzy match on basename or display name
    case Map.get(agents, name) do
      nil ->
        agents
        |> Map.values()
        |> Enum.filter(fn info ->
          lower_id = String.downcase(info.id)
          basename = info.id |> String.split("/") |> List.last() |> String.downcase()

          lower_id == lower_name or
            basename == lower_name or
            String.downcase(info.name) == lower_name
        end)

      info ->
        [info]
    end
  end

  # --- Agent activation ---

  defp activate([], _msg, _room_id, _state), do: :ok

  defp activate(agents, msg, room_id, state) do
    mentions = msg.mentions || []
    mode = activation_mode(mentions)

    # Filter out agents mid-handoff and muted, order by TF-IDF relevance
    # score (highest first). Index is always last when present:
    # infrastructure rounds out the room after specialists, never leads.
    scores = Egghead.Chat.Relevance.score(msg.content, state.corpus)

    {room_mode, muted_set} =
      try do
        rs = Room.get_state(room_id)
        {rs.mode, MapSet.new(rs.muted || [])}
      rescue
        _ -> {:serial, MapSet.new()}
      end

    # Filter out agents mid-handoff and muted agents. Muted agents
    # are skipped on open messages and @jam, but NOT on @everyone
    # (explicit intent) or direct @agent (explicit override).
    skip_muted? = mode != :huddle and not direct_mention?(mentions)

    agents_to_prompt =
      agents
      |> Enum.reject(fn info ->
        MapSet.member?(state.handoffs_in_progress, {info.id, room_id}) or
          (skip_muted? and MapSet.member?(muted_set, info.id))
      end)
      |> Enum.sort_by(fn info ->
        index_rank = if info.id == "index", do: 1, else: 0
        {index_rank, -(scores[info.id] || 0), info.id}
      end)

    agent_names = Enum.map_join(agents_to_prompt, ", ", & &1.id)
    Logger.info("Coordinator: activating agents (#{mode}): #{agent_names}")

    case mode do
      :jam ->
        # Parallel activation with a low-threshold hint for each agent.
        # Agents fire concurrently and don't see peers' in-flight output —
        # that's the point (cacophony).
        broadcast_activation(room_id, length(agents_to_prompt))

        Enum.each(agents_to_prompt, fn agent_info ->
          Task.start(fn ->
            prompt_agent_in_room(agent_info.id, room_id, msg.content, activation: :jam)
          end)
        end)

      :huddle ->
        # Serial roll-call. Every agent must respond; `/pass` is not allowed
        # (the Session prompt enforces this via the `:huddle` addendum).
        Task.start(fn ->
          Enum.each(agents_to_prompt, fn agent_info ->
            broadcast_activation(room_id, 1)
            prompt_agent_in_room(agent_info.id, room_id, msg.content, activation: :huddle)
          end)
        end)

      :normal when room_mode == :staggered and length(agents_to_prompt) > 1 ->
        # Staggered (opt-in): each agent runs in its own Task. A coordinator
        # Task subscribes to PubSub and spawns agents with stagger delays.
        Task.start(fn ->
          Phoenix.PubSub.subscribe(@pubsub, Room.topic(room_id))

          agents_to_prompt
          |> Enum.with_index()
          |> Enum.each(fn {agent_info, idx} ->
            if idx > 0 do
              # Wait for previous agent's tool call, completion, pass, or 3s
              receive do
                {:agent_tool_call, ^room_id, _, _, _} -> :ok
                {:agent_message, %{room_id: ^room_id}} -> :ok
                {:agent_passed, _} -> :ok
              after
                3_000 -> :ok
              end
            end

            broadcast_activation(room_id, 1)

            # Each agent runs in its own Task so this process stays free
            # to receive PubSub events for stagger timing
            Task.start(fn ->
              prompt_agent_in_room(agent_info.id, room_id, msg.content, activation: :normal)
            end)
          end)
        end)

      :normal ->
        # Serial (default): strict A-finishes-then-B in one Task
        Task.start(fn ->
          Enum.each(agents_to_prompt, fn agent_info ->
            broadcast_activation(room_id, 1)
            prompt_agent_in_room(agent_info.id, room_id, msg.content, activation: :normal)
          end)
        end)
    end
  end

  # The Coordinator's only job: pass the message and room context to the agent.
  # The agent handles its own context building, usage tracking, and handoff.
  defp prompt_agent_in_room(agent_id, room_id, message, opts \\ []) do
    activation = Keyword.get(opts, :activation, :normal)
    transcript = Room.get_transcript(room_id)
    room_state = Room.get_state(room_id)

    room_context = %{
      id: room_id,
      transcript: transcript,
      agents: room_state.agents,
      activation: activation
    }

    # Streaming is RAW: every text delta is broadcast immediately to
    # PubSub subscribers. Display-side buffering (e.g. paragraph batching
    # for the TUI's IRC view) belongs to the consumer, not here. Other
    # watchers — RoomLogger, MCP egghead_chat, future Phoenix Channels —
    # need access to the unbuffered token stream.
    #
    # We still need a per-call cumulative accumulator so we can push
    # the running total to Room.streaming_update (read by the /pass
    # rescue path below and by tools that ask "what has this agent
    # said so far?"). This MUST live in its own process: on_chunk runs
    # inside the Session GenServer (where Req.post executes), not in
    # this Task — so the process dictionary cannot be used here without
    # leaking state across sequential prompts to the same Session and
    # corrupting later messages with text from earlier turns.
    {:ok, buffer_pid} = Agent.start_link(fn -> "" end)

    # Belt-and-suspenders: ensure no stale in_progress text from a
    # prior call lingers when this turn begins. Without this, even a
    # transient bug in the accumulator could cause the /pass rescue
    # path below to commit text from a previous turn.
    Room.clear_in_progress(room_id, agent_id)

    on_chunk = fn
      {:text, delta} ->
        Phoenix.PubSub.broadcast(
          @pubsub,
          Room.topic(room_id),
          {:agent_streaming, room_id, agent_id, delta}
        )

        cumulative =
          Agent.get_and_update(buffer_pid, fn cum ->
            new = cum <> delta
            {new, new}
          end)

        Room.streaming_update(room_id, agent_id, cumulative)

      {:block_done, %{"type" => "tool_use", "name" => name} = block} ->
        # Reset the cumulative before the tool call so subsequent text
        # streams (after the tool result comes back) don't double-count
        # earlier text.
        Agent.update(buffer_pid, fn _ -> "" end)

        Phoenix.PubSub.broadcast(
          @pubsub,
          Room.topic(room_id),
          {:agent_tool_call, room_id, agent_id, name, block["input"]}
        )

      _ ->
        :ok
    end

    result =
      try do
        Egghead.Agent.prompt(agent_id, message, room: room_context, on_chunk: on_chunk)
      after
        # Always tear down the buffer Agent so we don't leak processes
        # if Egghead.Agent.prompt raises.
        if Process.alive?(buffer_pid), do: Agent.stop(buffer_pid)
      end

    case result do
      {:ok, %{text: text, usage: usage}} ->
        if pass_response?(text) do
          # The agent's final text is a pass. But an agent may have streamed
          # substantive content DURING tool rounds before deciding to yield
          # — in that case we commit the substantive part rather than
          # throwing it away. When the in-progress buffer contains only the
          # pass token itself, it's a pure pass with no content to rescue.
          in_progress = Room.get_in_progress(room_id, agent_id)

          if has_substantive_content?(in_progress) do
            Logger.debug("Coordinator: #{agent_id} streamed content, committing despite /pass")
            Room.agent_respond(room_id, agent_id, String.trim(in_progress), usage: usage)
          else
            Logger.debug("Coordinator: #{agent_id} passed (nothing to add)")
            # Room.agent_pass commits `/pass` to transcript AND broadcasts
            # :agent_passed (in-progress is cleared inside the handler).
            Room.agent_pass(room_id, agent_id)
          end
        else
          Room.agent_respond(room_id, agent_id, text, usage: usage)
        end

      {:error, reason} ->
        Logger.warning("Coordinator: agent #{agent_id} failed: #{inspect(reason)}")
        Room.clear_in_progress(room_id, agent_id)
        broadcast_pass(room_id, agent_id)
    end
  end

  # `/pass` counts as a pass only if it appears on a line by itself
  # (trimmed). An agent discussing the token as a concept in prose is
  # not a pass.
  defp pass_response?(text) do
    text
    |> String.split("\n")
    |> Enum.any?(&pass_line?/1)
  end

  defp pass_line?(line), do: String.trim(line) == "/pass"

  # Does the streamed in-progress buffer contain anything worth rescuing
  # when the agent's final answer is a pass? Returns false for nil, empty,
  # whitespace-only, or buffers whose non-blank lines are all pass tokens.
  defp has_substantive_content?(nil), do: false

  defp has_substantive_content?(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.reject(fn line -> String.trim(line) == "" end)
    |> Enum.any?(fn line -> not pass_line?(line) end)
  end

  defp broadcast_activation(room_id, count) do
    Phoenix.PubSub.broadcast(@pubsub, Room.topic(room_id), {:agents_activated, count})
  end

  defp broadcast_pass(room_id, agent_id) do
    Phoenix.PubSub.broadcast(@pubsub, Room.topic(room_id), {:agent_passed, agent_id})
  end

  # Trim a terminate reason for display in a single chat line. Erlang
  # exit reasons can be deeply nested; we keep the head and a short
  # suffix so the user gets a hint without the line wrapping forever.
  defp format_lifecycle_reason(reason) do
    full = inspect(reason, limit: 5, printable_limit: 80)
    if String.length(full) > 80, do: String.slice(full, 0, 77) <> "...", else: full
  end
end
