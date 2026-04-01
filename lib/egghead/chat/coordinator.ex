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
  def handle_info({:human_message, %{room_id: room_id} = msg}, state) do
    agents_to_activate = tier1_filter(msg, state.agents)
    activate(agents_to_activate, msg, room_id, state)
    {:noreply, state}
  end

  def handle_info({:human_message, msg}, state) do
    room_id = state.rooms |> MapSet.to_list() |> List.first()

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

  def handle_info({:agent_mentions, from_agent, mentioned_ids}, state) do
    room_id = state.rooms |> MapSet.to_list() |> List.first()

    agents =
      mentioned_ids
      |> Enum.flat_map(fn id ->
        case Map.get(state.agents, id) || Map.get(state.agents, "agents/#{id}") do
          nil -> []
          info -> [info]
        end
      end)

    if agents != [] and room_id do
      Logger.info("Coordinator: #{from_agent} mentioned #{Enum.map_join(agents, ", ", & &1.id)}")

      Enum.each(agents, fn agent_info ->
        Task.start(fn ->
          prompt_agent_in_room(agent_info.id, room_id)
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
    # Separate egghead from other agents
    {egghead_agents, other_agents} = Enum.split_with(agents, &(&1.id == "egghead"))

    if other_agents == [] and egghead_agents != [] do
      # No other agents — egghead responds as the fallback
      Logger.info("Coordinator: no other agents, egghead responding")

      Task.start(fn ->
        prompt_agent_in_room("egghead", room_id, msg.content)
      end)
    else
      # Other agents handle it — egghead stays out
      agent_names = Enum.map_join(other_agents, ", ", & &1.id)
      Logger.info("Coordinator: activating agents: #{agent_names}")

      Enum.each(other_agents, fn agent_info ->
        Task.start(fn ->
          prompt_agent_in_room(agent_info.id, room_id, msg.content)
        end)
      end)
    end
  end

  defp prompt_agent_in_room(agent_id, room_id) do
    # Activated via @-mention — build context from transcript
    transcript = Room.get_transcript(room_id)

    context =
      transcript
      |> Enum.take(-10)
      |> Enum.map_join("\n", fn m -> "#{m.sender}: #{m.content}" end)

    prompt_agent_in_room(
      agent_id,
      room_id,
      "You were mentioned in a conversation. Recent transcript:\n\n#{context}"
    )
  end

  defp prompt_agent_in_room(agent_id, room_id, message) do
    # Build context from room transcript
    transcript = Room.get_transcript(room_id)
    room_state = Room.get_state(room_id)
    other_agents = Enum.join(room_state.agents, ", ")

    context_prefix = """
    You are in chat room "#{room_id}" with agents: #{other_agents}.
    Recent conversation:
    #{format_transcript(transcript)}

    Respond to this message:
    """

    full_message = context_prefix <> message

    case Egghead.Agent.prompt(agent_id, full_message) do
      {:ok, %{text: text}} ->
        if String.trim(text) == "[PASS]" do
          Logger.debug("Coordinator: #{agent_id} passed (nothing to add)")
        else
          Room.agent_respond(room_id, agent_id, text)
        end

      {:error, reason} ->
        Logger.warning("Coordinator: agent #{agent_id} failed: #{inspect(reason)}")
    end
  end

  defp format_transcript(transcript) do
    transcript
    |> Enum.take(-20)
    |> Enum.map_join("\n", fn m ->
      role = if m.role == :human, do: "[human]", else: "[#{m.sender}]"
      "#{role} #{m.content}"
    end)
  end
end
