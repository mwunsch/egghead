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
  @idle_timeout :timer.minutes(5)
  @pubsub Egghead.PubSub

  defmodule Sender do
    @moduledoc "Identifies who sent a message — human or agent."
    @type t :: %__MODULE__{type: :user | :agent, id: String.t(), name: String.t()}
    defstruct [:type, :id, :name]
  end

  defmodule Message do
    @moduledoc "A single message in a chat room transcript."
    defstruct [
      :id,
      :room_id,
      :sender,
      :content,
      :timestamp,
      :mentions,
      # Agent context tracking (nil for user messages)
      usage: nil
    ]
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
      # %{agent_id => %Message{}} — provisional streaming messages
      in_progress: %{},
      idle_timeout: nil,
      mode: :serial,
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
  User sends a message to the room. Resets the round budget.
  """
  @spec send_message(String.t(), String.t()) :: :ok
  def send_message(room_id, content) do
    user = Egghead.User.current()
    sender = %Sender{type: :user, id: user.id, name: user.name}
    GenServer.call(room_name(room_id), {:send_message, sender, content})
  end

  @doc """
  Agent sends a response to the room.

  `opts` can include:
  - `:usage` — `%{input_tokens: n, output_tokens: n, session_tokens: n, context_window: n}`
  """
  @spec agent_respond(String.t(), String.t(), String.t(), keyword()) :: :ok
  def agent_respond(room_id, agent_id, content, opts \\ []) do
    name = agent_id |> String.split("/") |> List.last() |> String.capitalize()
    sender = %Sender{type: :agent, id: agent_id, name: name}
    usage = Keyword.get(opts, :usage)
    GenServer.call(room_name(room_id), {:agent_respond, sender, content, usage})
  end

  @doc """
  Update an agent's in-progress (streaming) text. Provisional — replaced
  by `agent_respond` when the agent finishes.
  """
  @spec streaming_update(String.t(), String.t(), String.t()) :: :ok
  def streaming_update(room_id, agent_id, partial_text) do
    GenServer.cast(room_name(room_id), {:streaming_update, agent_id, partial_text})
  end

  @doc """
  Get an agent's in-progress text, or nil if none.
  """
  @spec get_in_progress(String.t(), String.t()) :: String.t() | nil
  def get_in_progress(room_id, agent_id) do
    GenServer.call(room_name(room_id), {:get_in_progress, agent_id})
  end

  @doc """
  Clear an agent's in-progress text (e.g., on [PASS]).
  """
  @spec clear_in_progress(String.t(), String.t()) :: :ok
  def clear_in_progress(room_id, agent_id) do
    GenServer.cast(room_name(room_id), {:clear_in_progress, agent_id})
  end

  @doc """
  Set the room's activation mode at runtime.
  """
  @spec set_mode(String.t(), :staggered | :serial) :: :ok
  def set_mode(room_id, mode) when mode in [:staggered, :serial] do
    GenServer.call(room_name(room_id), {:set_mode, mode})
  end

  @doc """
  Human grants more turns (like `/continue`).
  """
  @spec continue(String.t()) :: :ok
  def continue(room_id) do
    GenServer.call(room_name(room_id), :continue)
  end

  @doc """
  Save the room transcript as a deliberation record in the store.
  Returns `{:ok, record_id}`.
  """
  @spec save_transcript(String.t()) :: {:ok, String.t()} | {:error, term()}
  def save_transcript(room_id) do
    GenServer.call(room_name(room_id), :save_transcript)
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
    idle_timeout = if Keyword.get(opts, :idle_timeout), do: @idle_timeout

    Logger.info("Chat room started: #{id}")

    mode = Keyword.get(opts, :mode, :serial)

    state = %State{
      id: id,
      round_budget: round_budget,
      rounds_remaining: round_budget,
      idle_timeout: idle_timeout,
      mode: mode
    }

    if idle_timeout, do: {:ok, state, idle_timeout}, else: {:ok, state}
  end

  @impl true
  def handle_call({:send_message, %Sender{} = sender, content}, _from, state) do
    mentions = extract_mentions(content)

    msg = %Message{
      id: generate_id(),
      room_id: state.id,
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

    broadcast(state.id, {:user_message, msg})

    reply_with_timeout(:ok, state)
  end

  def handle_call({:agent_respond, %Sender{} = sender, content, usage}, _from, state) do
    mentions = extract_mentions(content)

    msg = %Message{
      id: generate_id(),
      room_id: state.id,
      sender: sender,
      content: content,
      timestamp: DateTime.utc_now(),
      mentions: mentions,
      usage: usage
    }

    state = %{
      state
      | transcript: state.transcript ++ [msg],
        current_round_responded: MapSet.put(state.current_round_responded, sender.id),
        in_progress: Map.delete(state.in_progress, sender.id)
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

          broadcast(state.id, {:agent_mentions, state.id, sender.id, agent_mentions})
          state
        else
          # Budget exhausted — queue the mentions
          state = %{
            state
            | rounds_remaining: 0,
              status: :waiting,
              pending_mentions: state.pending_mentions ++ [{sender.id, agent_mentions}]
          }

          broadcast(state.id, :budget_exhausted)
          state
        end
      else
        state
      end

    reply_with_timeout(:ok, state)
  end

  def handle_call(:save_transcript, _from, state) do
    result = persist_transcript(state)
    {:reply, result, state}
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
      broadcast(state.id, {:agent_mentions, state.id, from_agent, mentioned})
    end)

    reply_with_timeout(:ok, state)
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
    format_msg = fn msg ->
      %{
        id: msg.id,
        room_id: msg.room_id,
        sender: %{
          type: msg.sender.type,
          id: msg.sender.id,
          name: msg.sender.name
        },
        content: msg.content,
        timestamp: msg.timestamp,
        mentions: msg.mentions,
        usage: msg.usage
      }
    end

    committed = Enum.map(state.transcript, format_msg)
    in_progress = state.in_progress |> Map.values() |> Enum.map(format_msg)

    {:reply, committed ++ in_progress, state}
  end

  def handle_call(:get_state, _from, state) do
    info = %{
      id: state.id,
      agents: MapSet.to_list(state.agents),
      status: state.status,
      rounds_remaining: state.rounds_remaining,
      round_budget: state.round_budget,
      pending_mentions: length(state.pending_mentions),
      message_count: length(state.transcript),
      mode: state.mode
    }

    {:reply, info, state}
  end

  def handle_call({:set_mode, mode}, _from, state) do
    {:reply, :ok, %{state | mode: mode}}
  end

  def handle_call({:get_in_progress, agent_id}, _from, state) do
    content =
      case Map.get(state.in_progress, agent_id) do
        %{content: text} -> text
        _ -> nil
      end

    {:reply, content, state}
  end

  @impl true
  def handle_cast({:streaming_update, agent_id, partial_text}, state) do
    name = agent_id |> String.split("/") |> List.last() |> String.capitalize()
    sender = %Sender{type: :agent, id: agent_id, name: name}

    msg = %Message{
      id: "in_progress_#{agent_id}",
      room_id: state.id,
      sender: sender,
      content: partial_text,
      timestamp: DateTime.utc_now(),
      mentions: []
    }

    state = %{state | in_progress: Map.put(state.in_progress, agent_id, msg)}
    {:noreply, state}
  end

  def handle_cast({:clear_in_progress, agent_id}, state) do
    state = %{state | in_progress: Map.delete(state.in_progress, agent_id)}
    {:noreply, state}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.info("Room #{state.id}: idle timeout, shutting down")
    {:stop, :normal, state}
  end

  # --- Private helpers ---

  defp reply_with_timeout(reply, state) do
    if state.idle_timeout do
      {:reply, reply, state, state.idle_timeout}
    else
      {:reply, reply, state}
    end
  end

  @doc """
  Render a transcript (list of messages as returned by
  `get_transcript/1`) as the canonical markdown body shared by
  `/save` (persisted as a deliberation record) and `/copy`
  (copied to the clipboard).
  """
  @spec format_transcript([map()]) :: String.t()
  def format_transcript(transcript) when is_list(transcript) do
    Enum.map_join(transcript, "\n\n", fn msg ->
      sender_label =
        case msg.sender do
          %{type: :user, name: name} -> "**#{name}**"
          %{type: :agent, name: name, id: id} -> "**#{name}** (`#{id}`)"
          _ -> "**unknown**"
        end

      timestamp = DateTime.to_iso8601(msg.timestamp)
      "#{sender_label} — #{timestamp}\n\n#{msg.content}"
    end)
  end

  defp persist_transcript(state) do
    if state.transcript == [] do
      {:error, :empty_transcript}
    else
      record_id = "chat/#{state.id}"

      body = format_transcript(state.transcript)

      # Collect all agent ids and mentioned record ids
      agent_ids =
        state.transcript
        |> Enum.filter(&(&1.sender.type == :agent))
        |> Enum.map(& &1.sender.id)
        |> Enum.uniq()

      attrs = %{
        "id" => record_id,
        "title" => "Chat: #{state.id}",
        "tags" => ["chat", "deliberation"],
        "links" => agent_ids,
        "class" => "deliberation",
        "body" => body
      }

      case Egghead.create_record(attrs) do
        {:ok, record} ->
          Logger.info("Room #{state.id}: transcript saved as #{record.id}")
          {:ok, record.id}

        {:error, :already_exists} ->
          # Update existing transcript
          case Egghead.update_record(record_id, %{"body" => body, "links" => agent_ids}) do
            {:ok, record} ->
              Logger.info("Room #{state.id}: transcript updated at #{record.id}")
              {:ok, record.id}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp broadcast(room_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, topic(room_id), event)
  end

  defp extract_mentions(content) do
    ~r/@([\w][\w\/\-]*)/
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
