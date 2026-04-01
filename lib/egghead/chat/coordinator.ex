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
    defstruct [:id, :name, :capabilities, :tags]
  end

  defmodule State do
    @moduledoc false
    defstruct agents: %{}, rooms: MapSet.new()
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
    {:ok, %State{}}
  end

  @impl true
  def handle_cast({:register_agent, agent_id, metadata}, state) do
    info = %AgentInfo{
      id: agent_id,
      name: metadata[:name] || agent_id,
      capabilities: metadata[:capabilities] || [],
      tags: metadata[:tags] || []
    }

    state = %{state | agents: Map.put(state.agents, agent_id, info)}
    Logger.debug("Coordinator: registered agent #{agent_id}")
    {:noreply, state}
  end

  def handle_cast({:unregister_agent, agent_id}, state) do
    state = %{state | agents: Map.delete(state.agents, agent_id)}
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
      |> Enum.flat_map(fn id ->
        case Map.get(state.agents, id) || Map.get(state.agents, "agents/#{id}") do
          nil -> []
          info -> [info]
        end
      end)

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

  def handle_info({:agent_message, _msg}, state) do
    # Agent spoke — visible to all via PubSub, no coordinator action needed
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

  # --- Tier 1: Structural filter (zero tokens) ---

  defp tier1_filter(msg, agents) do
    mentions = msg.mentions || []

    cond do
      # @everyone or @channel → activate ALL agents
      "everyone" in mentions or "channel" in mentions ->
        Map.values(agents)

      # @specific-agent → activate just that agent
      mentions != [] ->
        mentions
        |> Enum.flat_map(fn name ->
          find_agent(agents, name)
        end)

      # Open message (no @-mention) → activate all for now
      # TODO: implement graph-proximity filtering and tier 2 LLM gate
      true ->
        Map.values(agents)
    end
  end

  defp find_agent(agents, name) do
    lower_name = String.downcase(name)

    # Try exact match first
    case Map.get(agents, name) do
      nil ->
        # Try agents/ prefix
        case Map.get(agents, "agents/#{name}") do
          nil ->
            # Fuzzy: case-insensitive match against id or name
            agents
            |> Map.values()
            |> Enum.filter(fn info ->
              String.downcase(info.id) == lower_name or
                String.downcase(info.id) == "agents/#{lower_name}" or
                String.downcase(info.name) == lower_name
            end)

          info ->
            [info]
        end

      info ->
        [info]
    end
  end

  # --- Agent activation ---

  defp activate([], _msg, _room_id, _state), do: :ok

  defp activate(agents, msg, room_id, _state) do
    # Egghead (coordinator) only participates when:
    # 1. Directly @-mentioned
    # 2. No other agents available (fallback)
    # Otherwise it stays out and lets the specialist agents work
    mentions = msg.mentions || []
    egghead_mentioned = "egghead" in mentions

    {egghead_agents, other_agents} = Enum.split_with(agents, &(&1.id == "egghead"))

    agents_to_prompt =
      cond do
        egghead_mentioned ->
          # Egghead was directly addressed — include it alongside others
          agents

        other_agents == [] and egghead_agents != [] ->
          # No specialists available — egghead responds as fallback
          Logger.info("Coordinator: no other agents, egghead responding")
          egghead_agents

        true ->
          # Normal case — specialists only
          other_agents
      end

    agent_names = Enum.map_join(agents_to_prompt, ", ", & &1.id)
    Logger.info("Coordinator: activating agents: #{agent_names}")

    broadcast_activation(room_id, length(agents_to_prompt))

    Enum.each(agents_to_prompt, fn agent_info ->
      Task.start(fn ->
        prompt_agent_in_room(agent_info.id, room_id, msg.content)
      end)
    end)
  end

  # The Coordinator's only job: pass the message and room context to the agent.
  # The agent handles its own context building, usage tracking, and handoff.
  defp prompt_agent_in_room(agent_id, room_id, message) do
    transcript = Room.get_transcript(room_id)
    room_state = Room.get_state(room_id)

    room_context = %{
      id: room_id,
      transcript: transcript,
      agents: room_state.agents
    }

    on_chunk = fn
      {:text, delta} ->
        Phoenix.PubSub.broadcast(
          @pubsub,
          Room.topic(room_id),
          {:agent_streaming, room_id, agent_id, delta}
        )

      {:block_done, %{"type" => "tool_use", "name" => name} = block} ->
        Phoenix.PubSub.broadcast(
          @pubsub,
          Room.topic(room_id),
          {:agent_tool_call, room_id, agent_id, name, block["input"]}
        )

      _ ->
        :ok
    end

    case Egghead.Agent.prompt(agent_id, message, room: room_context, on_chunk: on_chunk) do
      {:ok, %{text: text, usage: usage}} ->
        if String.trim(text) == "[PASS]" do
          Logger.debug("Coordinator: #{agent_id} passed (nothing to add)")
          broadcast_pass(room_id, agent_id)
        else
          Room.agent_respond(room_id, agent_id, text, usage: usage)
        end

      {:error, reason} ->
        Logger.warning("Coordinator: agent #{agent_id} failed: #{inspect(reason)}")
        broadcast_pass(room_id, agent_id)
    end
  end

  defp broadcast_activation(room_id, count) do
    Phoenix.PubSub.broadcast(@pubsub, Room.topic(room_id), {:agents_activated, count})
  end

  defp broadcast_pass(room_id, agent_id) do
    Phoenix.PubSub.broadcast(@pubsub, Room.topic(room_id), {:agent_passed, agent_id})
  end
end
