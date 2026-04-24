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

  # How many agent messages can land before we ask the human to
  # /continue. One tick per agent response (not per round or per
  # mention); passes don't count. Raised from 5 when the tick
  # semantics shifted to per-message — 5 was effectively nothing
  # once open-activation rounds (3-4 specialists) counted honestly.
  @default_round_budget 15
  @idle_timeout :timer.minutes(5)
  @pubsub Egghead.PubSub

  defmodule Sender do
    @moduledoc "Identifies who sent a message — human or agent."
    @type t :: %__MODULE__{type: :user | :agent, id: String.t(), name: String.t()}
    defstruct [:type, :id, :name]
  end

  defmodule Message do
    @moduledoc "A single message in a chat room transcript."
    @type t :: %__MODULE__{
            id: String.t(),
            room_id: String.t(),
            sender: Egghead.Chat.Room.Sender.t(),
            content: String.t(),
            timestamp: DateTime.t(),
            mentions: [String.t()] | nil,
            usage: map() | nil
          }
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
      round_budget: 15,
      rounds_remaining: 0,
      current_round_responded: MapSet.new(),
      pending_mentions: [],
      # %{agent_id => %Message{}} — provisional streaming messages
      in_progress: %{},
      muted: MapSet.new(),
      idle_timeout: nil,
      mode: :serial,
      status: :waiting,
      # When true, agent_respond / agent_pass / agent_mentions are
      # all swallowed: in-flight tasks finishing late don't get
      # appended or fanned out, and Coordinator stops spawning new
      # cascades. Cleared on send_message (next user turn) or
      # continue (explicit resume).
      halted: false
    ]
  end

  # --- Public API ---

  @doc """
  Starts a chat room.
  """
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    name = room_name(id)
    # start (not start_link) so rooms survive when the creating process
    # exits — critical for rooms created via RPC from CLI clients.
    GenServer.start(__MODULE__, opts, name: name)
  end

  @doc """
  User sends a message to the room. Resets the round budget.
  """
  @spec send_message(String.t(), String.t()) :: :ok
  def send_message(room_id, content) do
    user = Egghead.User.current()
    sender = %Sender{type: :user, id: user.id, name: user.name}
    Egghead.Node.call(room_name(room_id), {:send_message, sender, content})
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
    Egghead.Node.call(room_name(room_id), {:agent_respond, sender, content, usage})
  end

  @doc """
  Record that an agent yielded its turn via `/pass`. Commits a `/pass`
  message to the transcript (so peers reading the transcript see the
  explicit yield and rehydrate is deterministic) and broadcasts
  `{:agent_passed, agent_id}` for UI consumers to render as an action
  line. Does NOT fire `:agent_message` — callers rendering the yield
  as an atmospheric action should subscribe to `:agent_passed`.
  """
  @spec agent_pass(String.t(), String.t()) :: :ok
  def agent_pass(room_id, agent_id) do
    name = agent_id |> String.split("/") |> List.last() |> String.capitalize()
    sender = %Sender{type: :agent, id: agent_id, name: name}
    Egghead.Node.call(room_name(room_id), {:agent_pass, sender})
  end

  @doc """
  Update an agent's in-progress (streaming) text. Provisional — replaced
  by `agent_respond` when the agent finishes.
  """
  @spec streaming_update(String.t(), String.t(), String.t()) :: :ok
  def streaming_update(room_id, agent_id, partial_text) do
    Egghead.Node.cast(room_name(room_id), {:streaming_update, agent_id, partial_text})
  end

  @doc """
  Get an agent's in-progress text, or nil if none.
  """
  @spec get_in_progress(String.t(), String.t()) :: String.t() | nil
  def get_in_progress(room_id, agent_id) do
    Egghead.Node.call(room_name(room_id), {:get_in_progress, agent_id})
  end

  @doc """
  Clear an agent's in-progress text (e.g., on `/pass`).
  """
  @spec clear_in_progress(String.t(), String.t()) :: :ok
  def clear_in_progress(room_id, agent_id) do
    Egghead.Node.cast(room_name(room_id), {:clear_in_progress, agent_id})
  end

  @spec mute(String.t(), String.t()) :: :ok
  def mute(room_id, agent_id) do
    Egghead.Node.call(room_name(room_id), {:mute, agent_id})
  end

  @spec unmute(String.t(), String.t()) :: :ok
  def unmute(room_id, agent_id) do
    Egghead.Node.call(room_name(room_id), {:unmute, agent_id})
  end

  @spec muted(String.t()) :: [String.t()]
  def muted(room_id) do
    Egghead.Node.call(room_name(room_id), :muted)
  end

  @doc """
  Human grants more turns (like `/continue`).
  """
  @spec continue(String.t()) :: :ok
  def continue(room_id) do
    Egghead.Node.call(room_name(room_id), :continue)
  end

  @doc """
  Interrupt all in-flight agent activity in the room.

  Clears any queued @-mentions, sets the room to `:waiting`, and
  broadcasts `{:halted, room_id}` so subscribed Sessions can abort
  their current LLM call. Agents stay alive; they just stop talking
  until the next user message.
  """
  @spec halt(String.t()) :: :ok
  def halt(room_id) do
    Egghead.Node.call(room_name(room_id), :halt)
  end

  @doc """
  Save the room transcript as a deliberation record in the store.
  Returns `{:ok, record_id}`.
  """
  @spec save_transcript(String.t()) :: {:ok, String.t()} | {:error, term()}
  def save_transcript(room_id) do
    Egghead.Node.call(room_name(room_id), :save_transcript)
  end

  @doc """
  An agent joins the room.
  """
  @spec join(String.t(), String.t()) :: :ok
  def join(room_id, agent_id) do
    Egghead.Node.call(room_name(room_id), {:join, agent_id})
  end

  @doc """
  An agent leaves the room.
  """
  @spec leave(String.t(), String.t()) :: :ok
  def leave(room_id, agent_id) do
    Egghead.Node.call(room_name(room_id), {:leave, agent_id})
  end

  @doc """
  Returns the full transcript.
  """
  @spec get_transcript(String.t()) :: [map()]
  def get_transcript(room_id) do
    Egghead.Node.call(room_name(room_id), :get_transcript)
  end

  @doc """
  Rehydrate a room from a saved `class: transcript` record.

  - If a live room with the derived id is already running, returns it
    as-is (no overwrite — `/join` of a running room and `/join` of a
    saved transcript with the same id should be the same act).
  - Otherwise reads the record, parses the body, and starts a new
    Room with the transcript pre-populated.

  The room id is derived by stripping the `chat/` prefix from the
  record id.
  """
  @spec from_transcript(String.t()) ::
          {:ok, String.t()} | {:error, :not_found | :wrong_class | :parse_failed | term()}
  def from_transcript(record_id) when is_binary(record_id) do
    # Room creation must happen on the node that owns the supervision tree
    case Egghead.Node.server_node() do
      nil -> from_transcript_local(record_id)
      node -> :rpc.call(node, __MODULE__, :from_transcript_local, [record_id])
    end
  end

  @doc false
  def from_transcript_local(record_id) do
    with {:ok, record} <- Egghead.get_record(record_id),
         :transcript <- record.class || :unknown,
         room_id <- derive_room_id(record_id),
         {:ok, messages} <- Egghead.Chat.TranscriptParser.parse(record.body || "", room_id) do
      cond do
        exists?(room_id) ->
          {:ok, room_id}

        true ->
          case start_link(id: room_id) do
            {:ok, _pid} ->
              GenServer.call(room_name(room_id), {:seed_transcript, messages})
              Egghead.Chat.Coordinator.watch_room(room_id)
              {:ok, room_id}

            {:error, {:already_started, _}} ->
              {:ok, room_id}

            {:error, reason} ->
              {:error, reason}
          end
      end
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} = err -> err
      class when is_atom(class) -> {:error, :wrong_class}
      _ -> {:error, :parse_failed}
    end
  end

  defp derive_room_id("chat/" <> rest), do: rest
  defp derive_room_id(other), do: other

  @doc """
  Whether a live room with this id is currently running.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?(room_id) do
    case Egghead.Node.server_node() do
      nil ->
        case Process.whereis(room_name(room_id)) do
          nil -> false
          pid -> Process.alive?(pid)
        end

      node ->
        :rpc.call(node, Process, :whereis, [room_name(room_id)]) not in [nil, :undefined]
    end
  end

  @doc """
  Ids of all currently-running rooms, sorted alphabetically.
  Discovered by scanning the registered atom namespace for
  `egghead_room_*` names.
  """
  @spec list_ids() :: [String.t()]
  def list_ids do
    registered =
      case Egghead.Node.server_node() do
        nil -> Process.registered()
        node -> :rpc.call(node, Process, :registered, [])
      end

    registered
    |> Enum.flat_map(fn name ->
      case Atom.to_string(name) do
        "egghead_room_" <> id -> [id]
        _ -> []
      end
    end)
    |> Enum.sort()
  end

  @doc """
  Returns the room state (agents, status, turns remaining).
  """
  @spec get_state(String.t()) :: map()
  def get_state(room_id) do
    Egghead.Node.call(room_name(room_id), :get_state)
  end

  @doc """
  Stops a room. Broadcasts `{:room_stopped, room_id}` before shutdown
  so subscribed clients can switch away.
  """
  @spec stop(String.t()) :: :ok
  def stop(room_id) do
    Phoenix.PubSub.broadcast(@pubsub, topic(room_id), {:room_stopped, room_id})

    case Egghead.Node.server_node() do
      nil -> GenServer.stop(room_name(room_id), :normal, 5_000)
      node -> :rpc.call(node, GenServer, :stop, [room_name(room_id), :normal, 5_000])
    end

    :ok
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
        status: :active,
        halted: false
    }

    broadcast(state.id, {:user_message, msg})

    reply_with_timeout(:ok, state)
  end

  def handle_call({:seed_transcript, messages}, _from, state) do
    # Seed an empty room with messages parsed from a saved transcript.
    # Idempotent guard: refuse to overwrite if anything is already there.
    case state.transcript do
      [] ->
        agents =
          messages
          |> Enum.filter(&(&1.sender.type == :agent))
          |> Enum.map(& &1.sender.id)
          |> Enum.uniq()
          |> MapSet.new()

        state = %{state | transcript: messages, agents: MapSet.union(state.agents, agents)}
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :not_empty}, state}
    end
  end

  # Halted: a late-arriving response or pass from an in-flight task that
  # finished after the user hit halt. Swallow without persisting or
  # broadcasting — the user said stop. Reply :ok so the caller doesn't
  # see this as an error path; we already returned :halted to whatever
  # was actually waiting on the LLM call.
  def handle_call({:agent_respond, %Sender{}, _content, _usage}, _from, %{halted: true} = state),
    do: reply_with_timeout(:ok, state)

  def handle_call({:agent_pass, %Sender{}}, _from, %{halted: true} = state),
    do: reply_with_timeout(:ok, state)

  def handle_call({:agent_pass, %Sender{} = sender}, _from, state) do
    msg = %Message{
      id: generate_id(),
      room_id: state.id,
      sender: sender,
      content: "/pass",
      timestamp: DateTime.utc_now(),
      mentions: [],
      usage: nil
    }

    state = %{
      state
      | transcript: state.transcript ++ [msg],
        current_round_responded: MapSet.put(state.current_round_responded, sender.id),
        in_progress: Map.delete(state.in_progress, sender.id)
    }

    # Fire ONLY :agent_passed, not :agent_message — UI renders this as an
    # atmospheric action line via PassActions, not a regular agent message.
    broadcast(state.id, {:agent_passed, sender.id})

    {:reply, :ok, state}
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

    # Every agent response ticks the turn budget once. Passes don't
    # count (handled in agent_pass). This makes open-activation rounds
    # pay honestly (4 specialists responding → 4 ticks), same as a
    # chained @-mention cascade (1 tick per hop). Previously the
    # budget only fired on @-mention cascades, which produced weird
    # asymmetry between activation modes.
    new_remaining = state.rounds_remaining - 1
    exhausted_now? = state.rounds_remaining > 0 and new_remaining <= 0

    state = %{
      state
      | transcript: state.transcript ++ [msg],
        current_round_responded: MapSet.put(state.current_round_responded, sender.id),
        in_progress: Map.delete(state.in_progress, sender.id),
        rounds_remaining: max(new_remaining, 0)
    }

    broadcast(state.id, {:agent_message, msg})

    # @-mentions of specific agents trigger cascading activation.
    # @everyone / @channel are broadcast mentions handled elsewhere.
    agent_mentions = Enum.filter(mentions, &(&1 != "everyone" and &1 != "channel"))

    state =
      cond do
        # Budget has room and there are mentions: activate them.
        agent_mentions != [] and state.rounds_remaining > 0 ->
          broadcast(state.id, {:agent_mentions, state.id, sender.id, agent_mentions, content})
          state

        # Budget exhausted with mentions: queue for replay on /continue.
        agent_mentions != [] ->
          %{
            state
            | status: :waiting,
              pending_mentions: state.pending_mentions ++ [{sender.id, agent_mentions, content}]
          }

        # No mentions; the round finishes naturally.
        true ->
          state
      end

    # Announce budget exhaustion to UI clients the first time we hit
    # zero, so the "do you have anything to add?" nudge can render.
    # Fires regardless of whether mentions were queued: the human may
    # want to chime in even if the conversation would otherwise pause.
    state =
      if exhausted_now? do
        broadcast(state.id, :budget_exhausted)
        %{state | status: :waiting}
      else
        state
      end

    reply_with_timeout(:ok, state)
  end

  def handle_call(:save_transcript, _from, state) do
    result = persist_transcript(state)
    {:reply, result, state}
  end

  def handle_call(:halt, _from, state) do
    state = %{
      state
      | status: :waiting,
        pending_mentions: [],
        in_progress: %{},
        halted: true
    }

    broadcast(state.id, {:halted, state.id})
    reply_with_timeout(:ok, state)
  end

  def handle_call(:continue, _from, state) do
    pending = state.pending_mentions

    state = %{
      state
      | rounds_remaining: state.round_budget,
        current_round_responded: MapSet.new(),
        status: :active,
        pending_mentions: [],
        halted: false
    }

    broadcast(state.id, :continued)

    # Replay pending @-mentions that were queued when budget ran out
    Enum.each(pending, fn {from_agent, mentioned, mention_content} ->
      broadcast(
        state.id,
        {:agent_mentions, state.id, from_agent, mentioned, mention_content}
      )
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
      muted: MapSet.to_list(state.muted),
      status: state.status,
      rounds_remaining: state.rounds_remaining,
      round_budget: state.round_budget,
      pending_mentions: length(state.pending_mentions),
      message_count: length(state.transcript),
      mode: state.mode,
      halted: state.halted
    }

    {:reply, info, state}
  end

  def handle_call({:mute, agent_id}, _from, state) do
    state = %{state | muted: MapSet.put(state.muted, agent_id)}
    broadcast(state.id, {:muted_changed, agent_id, true})
    broadcast(state.id, {:system_notice, "#{agent_display_name(agent_id)} muted"})
    {:reply, :ok, state}
  end

  def handle_call({:unmute, agent_id}, _from, state) do
    state = %{state | muted: MapSet.delete(state.muted, agent_id)}
    broadcast(state.id, {:muted_changed, agent_id, false})
    broadcast(state.id, {:system_notice, "#{agent_display_name(agent_id)} unmuted"})
    {:reply, :ok, state}
  end

  def handle_call(:muted, _from, state) do
    {:reply, MapSet.to_list(state.muted), state}
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
        "tags" => ["chat", "transcript"],
        "links" => agent_ids,
        "class" => "transcript",
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

  defp agent_display_name(agent_id) do
    agent_id |> String.split("/") |> List.last() |> String.capitalize()
  end

  defp generate_id do
    "msg_#{:erlang.unique_integer([:positive, :monotonic])}"
  end

  defp room_name(id) do
    :"egghead_room_#{id}"
  end
end
