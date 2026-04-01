defmodule Egghead.Chat.Room do
  @moduledoc """
  A shared conversation space where multiple agents collaborate with a human.

  The Room holds the transcript and enforces the turn budget. Messages are
  broadcast via PubSub so all participants (agents, coordinator, UI clients)
  see them. The coordinator gates which agents activate; the room doesn't
  filter — it's the shared medium.

  Graph topology: every participant sees every message. The coordinator
  decides who speaks, not what's visible.
  """

  use GenServer

  require Logger

  @default_round_budget 5
  @pubsub Egghead.PubSub

  defmodule Message do
    @moduledoc false
    defstruct [:id, :role, :sender, :content, :timestamp, :mentions]
  end

  defmodule State do
    @moduledoc false
    defstruct [
      :id,
      transcript: [],
      agents: MapSet.new(),
      round_budget: 5,
      rounds_remaining: 0,
      current_round_responded: MapSet.new(),
      pending_mentions: [],
      status: :waiting
    ]
  end

  # --- Public API ---

  @doc """
  Starts a chat room.
  """
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    name = room_name(id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Human sends a message to the room. Resets the turn budget and
  broadcasts to all subscribers.
  """
  @spec send_message(String.t(), String.t(), String.t()) :: :ok
  def send_message(room_id, sender, content) do
    GenServer.call(room_name(room_id), {:send_message, sender, content})
  end

  @doc """
  Agent sends a response to the room. Decrements the turn budget.
  """
  @spec agent_respond(String.t(), String.t(), String.t()) :: :ok | {:error, :budget_exhausted}
  def agent_respond(room_id, agent_id, content) do
    GenServer.call(room_name(room_id), {:agent_respond, agent_id, content})
  end

  @doc """
  Human grants more turns (like `/continue`).
  """
  @spec continue(String.t()) :: :ok
  def continue(room_id) do
    GenServer.call(room_name(room_id), :continue)
  end

  @doc """
  An agent joins the room.
  """
  @spec join(String.t(), String.t()) :: :ok
  def join(room_id, agent_id) do
    GenServer.call(room_name(room_id), {:join, agent_id})
  end

  @doc """
  An agent leaves the room.
  """
  @spec leave(String.t(), String.t()) :: :ok
  def leave(room_id, agent_id) do
    GenServer.call(room_name(room_id), {:leave, agent_id})
  end

  @doc """
  Returns the full transcript.
  """
  @spec get_transcript(String.t()) :: [map()]
  def get_transcript(room_id) do
    GenServer.call(room_name(room_id), :get_transcript)
  end

  @doc """
  Returns the room state (agents, status, turns remaining).
  """
  @spec get_state(String.t()) :: map()
  def get_state(room_id) do
    GenServer.call(room_name(room_id), :get_state)
  end

  @doc """
  Returns the PubSub topic for a room.
  """
  @spec topic(String.t()) :: String.t()
  def topic(room_id), do: "room:#{room_id}"

  @doc """
  Subscribe to a room's messages.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(room_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(room_id))
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    round_budget = Keyword.get(opts, :round_budget, @default_round_budget)

    Logger.info("Chat room started: #{id}")

    {:ok,
     %State{
       id: id,
       round_budget: round_budget,
       rounds_remaining: round_budget
     }}
  end

  @impl true
  def handle_call({:send_message, sender, content}, _from, state) do
    mentions = extract_mentions(content)

    msg = %Message{
      id: generate_id(),
      role: :human,
      sender: sender,
      content: content,
      timestamp: DateTime.utc_now(),
      mentions: mentions
    }

    state = %{
      state
      | transcript: state.transcript ++ [msg],
        rounds_remaining: state.round_budget,
        current_round_responded: MapSet.new(),
        pending_mentions: [],
        status: :active
    }

    broadcast(state.id, {:human_message, msg})

    {:reply, :ok, state}
  end

  def handle_call({:agent_respond, agent_id, content}, _from, state) do
    mentions = extract_mentions(content)

    msg = %Message{
      id: generate_id(),
      role: :agent,
      sender: agent_id,
      content: content,
      timestamp: DateTime.utc_now(),
      mentions: mentions
    }

    # Track which agents have responded in this round
    state = %{
      state
      | transcript: state.transcript ++ [msg],
        current_round_responded: MapSet.put(state.current_round_responded, agent_id)
    }

    broadcast(state.id, {:agent_message, msg})

    # @-mentions start a new round
    agent_mentions = Enum.filter(mentions, &(&1 != "everyone" and &1 != "channel"))

    state =
      if agent_mentions != [] do
        # This agent is triggering a new round by @-mentioning others
        new_remaining = state.rounds_remaining - 1

        if new_remaining > 0 do
          state = %{
            state
            | rounds_remaining: new_remaining,
              current_round_responded: MapSet.new()
          }

          broadcast(state.id, {:agent_mentions, agent_id, agent_mentions})
          state
        else
          # Budget exhausted — queue the mentions
          state = %{
            state
            | rounds_remaining: 0,
              status: :waiting,
              pending_mentions: state.pending_mentions ++ [{agent_id, agent_mentions}]
          }

          broadcast(state.id, :budget_exhausted)
          state
        end
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call(:continue, _from, state) do
    pending = state.pending_mentions

    state = %{
      state
      | rounds_remaining: state.round_budget,
        current_round_responded: MapSet.new(),
        status: :active,
        pending_mentions: []
    }

    broadcast(state.id, :continued)

    # Replay pending @-mentions that were queued when budget ran out
    Enum.each(pending, fn {from_agent, mentioned} ->
      broadcast(state.id, {:agent_mentions, from_agent, mentioned})
    end)

    {:reply, :ok, state}
  end

  def handle_call({:join, agent_id}, _from, state) do
    state = %{state | agents: MapSet.put(state.agents, agent_id)}
    broadcast(state.id, {:agent_joined, agent_id})
    {:reply, :ok, state}
  end

  def handle_call({:leave, agent_id}, _from, state) do
    state = %{state | agents: MapSet.delete(state.agents, agent_id)}
    broadcast(state.id, {:agent_left, agent_id})
    {:reply, :ok, state}
  end

  def handle_call(:get_transcript, _from, state) do
    transcript =
      Enum.map(state.transcript, fn msg ->
        %{
          id: msg.id,
          role: msg.role,
          sender: msg.sender,
          content: msg.content,
          timestamp: msg.timestamp,
          mentions: msg.mentions
        }
      end)

    {:reply, transcript, state}
  end

  def handle_call(:get_state, _from, state) do
    info = %{
      id: state.id,
      agents: MapSet.to_list(state.agents),
      status: state.status,
      rounds_remaining: state.rounds_remaining,
      round_budget: state.round_budget,
      pending_mentions: length(state.pending_mentions),
      message_count: length(state.transcript)
    }

    {:reply, info, state}
  end

  # --- Private helpers ---

  defp broadcast(room_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, topic(room_id), event)
  end

  defp extract_mentions(content) do
    ~r/@(\w[\w\/]*)/
    |> Regex.scan(content)
    |> Enum.map(fn [_, name] -> name end)
  end

  defp generate_id do
    "msg_#{:erlang.unique_integer([:positive, :monotonic])}"
  end

  defp room_name(id) do
    :"egghead_room_#{id}"
  end
end
