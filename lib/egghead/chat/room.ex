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

  # Per-user-message activation budget. Each agent activation (direct,
  # @-mention, cascade hop) consumes one slot. Resets on the next user
  # message and on /continue. Computed from the room's roster size:
  # `clamp(ceil(1.5 * agent_count), floor, ceiling)`. 1.5x gives every
  # agent room to respond plus a partial cascade allowance — enough for
  # a real conversation, tight enough that the bar is actually reached
  # in active rooms. The floor keeps tiny rooms loose; the ceiling caps
  # blast radius in big rooms.
  @activation_budget_numerator 3
  @activation_budget_denominator 2
  @activation_budget_floor 6
  @activation_budget_ceiling 21

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
      # Activation budget: cap is a function of roster size,
      # consumed per agent activation (Coordinator gates).
      activation_budget: 0,
      activations_remaining: 0,
      pending_activations: [],
      # Test escape hatch: when set at start_link via the :activation_budget
      # opt, this pins the cap so it survives roster changes and
      # send_message recomputes. Production callers leave it nil.
      pinned_activation_budget: nil,
      # Latched once per turn so we don't spam :budget_exhausted on
      # every queued activation; reset on send_message and continue.
      budget_broadcast?: false,
      # Set when remaining hits 0 (or a queue happens) while sessions
      # are still in flight. The bar would lie if it fired now —
      # agents are visibly streaming. Drain to zero active_sessions,
      # then broadcast. Reset on send_message and continue.
      budget_exhausted_pending?: false,
      # Count of agent sessions that have been granted a slot via
      # try_activate but haven't yet committed via agent_respond /
      # agent_pass. Used to defer :budget_exhausted until the room
      # is genuinely idle, not just "no more slots left."
      active_sessions: 0,
      current_round_responded: MapSet.new(),
      # %{agent_id => %Message{}} — provisional streaming messages
      in_progress: %{},
      muted: MapSet.new(),
      idle_timeout: nil,
      mode: :serial,
      status: :waiting,
      # When true, agent_respond / agent_pass are swallowed: in-flight
      # tasks finishing late don't get appended or fanned out.
      # Cleared on send_message (next user turn) or continue.
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
  User sends a message to the room. Resets the activation budget.
  """
  @spec send_message(String.t(), String.t()) :: :ok
  def send_message(room_id, content) do
    user = Egghead.User.current()
    sender = %Sender{type: :user, id: user.id, name: user.name}
    Egghead.Node.call(room_name(room_id), {:send_message, sender, content})
  end

  @doc """
  Atomically check the activation budget and consume one slot.

  Returns `:ok` if a slot was reserved (caller proceeds with the
  agent's turn), or `:exhausted` if the budget is dry. The Coordinator
  calls this immediately before spawning each agent activation; on
  `:exhausted` the caller should `queue_activation/3` instead.
  """
  @spec try_activate(String.t(), String.t()) :: :ok | :exhausted
  def try_activate(room_id, agent_id) do
    Egghead.Node.call(room_name(room_id), {:try_activate, agent_id})
  end

  @doc """
  Push an agent activation onto the pending queue, to be replayed on
  the next `/continue`. Latches `:budget_exhausted` once per turn.
  """
  @spec queue_activation(String.t(), String.t(), keyword()) :: :ok
  def queue_activation(room_id, agent_id, opts \\ []) do
    Egghead.Node.call(room_name(room_id), {:queue_activation, agent_id, opts})
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
    idle_timeout = if Keyword.get(opts, :idle_timeout), do: @idle_timeout

    Logger.info("Chat room started: #{id}")

    mode = Keyword.get(opts, :mode, :serial)

    # Test escape hatch: pin the budget so it survives roster changes
    # and send_message recomputes. Production callers leave this unset
    # and the budget tracks the roster.
    pinned = Keyword.get(opts, :activation_budget)
    initial_budget = pinned || compute_activation_budget(MapSet.new())

    state = %State{
      id: id,
      activation_budget: initial_budget,
      activations_remaining: initial_budget,
      pinned_activation_budget: pinned,
      idle_timeout: idle_timeout,
      mode: mode
    }

    if idle_timeout, do: {:ok, state, idle_timeout}, else: {:ok, state}
  end

  # `clamp(2 * roster_size, 6, 21)`. Floor keeps tiny rooms loose,
  # ceiling caps big-room blast radius. Recomputed on roster change
  # and on every send_message — unless `pinned_activation_budget` is
  # set (test escape hatch), in which case that wins.
  defp budget_for(state) do
    case state.pinned_activation_budget do
      nil -> compute_activation_budget(state.agents)
      pinned -> pinned
    end
  end

  defp compute_activation_budget(agents) do
    raw =
      ceil(@activation_budget_numerator * MapSet.size(agents) / @activation_budget_denominator)

    raw |> max(@activation_budget_floor) |> min(@activation_budget_ceiling)
  end

  # Floor at 0 — late-arriving agent_respond / agent_pass from sessions
  # we already zeroed (e.g. via halt) must not push the count negative.
  defp decrement_active_session(state) do
    %{state | active_sessions: max(state.active_sessions - 1, 0)}
  end

  # Fire :budget_exhausted only when the room is genuinely paused: no
  # remaining slots AND no agent still streaming. Latched once per
  # turn via budget_broadcast?. Called from try_activate /
  # queue_activation (when exhaustion first arises) and from
  # agent_respond / agent_pass (when active sessions drain).
  defp maybe_broadcast_exhaustion(state) do
    cond do
      state.budget_broadcast? ->
        state

      state.activations_remaining == 0 and state.active_sessions == 0 ->
        broadcast(state.id, :budget_exhausted)
        %{state | budget_broadcast?: true, budget_exhausted_pending?: false, status: :waiting}

      state.activations_remaining == 0 ->
        %{state | budget_exhausted_pending?: true}

      true ->
        state
    end
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

    new_budget = budget_for(state)

    state = %{
      state
      | transcript: state.transcript ++ [msg],
        activation_budget: new_budget,
        activations_remaining: new_budget,
        pending_activations: [],
        budget_broadcast?: false,
        budget_exhausted_pending?: false,
        current_round_responded: MapSet.new(),
        status: :active,
        halted: false
    }

    broadcast(state.id, {:user_message, msg})

    reply_with_timeout(:ok, state)
  end

  def handle_call({:try_activate, _agent_id}, _from, state) do
    if state.activations_remaining > 0 do
      new_remaining = state.activations_remaining - 1

      state = %{
        state
        | activations_remaining: new_remaining,
          active_sessions: state.active_sessions + 1
      }

      # Crossing to zero marks "no more slots." But the bar means
      # "we're paused for you" — broadcasting it while the agent who
      # just took the last slot is still mid-stream reads as a lie.
      # Mark it pending; let agent_respond / agent_pass fire it when
      # active_sessions drains to zero.
      state =
        if new_remaining == 0 do
          maybe_broadcast_exhaustion(state)
        else
          state
        end

      reply_with_timeout(:ok, state)
    else
      reply_with_timeout(:exhausted, state)
    end
  end

  def handle_call({:queue_activation, agent_id, opts}, _from, state) do
    state = %{
      state
      | pending_activations: state.pending_activations ++ [{agent_id, opts}],
        budget_exhausted_pending?: true
    }

    state = maybe_broadcast_exhaustion(state)

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

    state =
      %{
        state
        | transcript: state.transcript ++ [msg],
          current_round_responded: MapSet.put(state.current_round_responded, sender.id),
          in_progress: Map.delete(state.in_progress, sender.id)
      }
      |> decrement_active_session()
      |> maybe_broadcast_exhaustion()

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

    state =
      %{
        state
        | transcript: state.transcript ++ [msg],
          current_round_responded: MapSet.put(state.current_round_responded, sender.id),
          in_progress: Map.delete(state.in_progress, sender.id)
      }
      |> decrement_active_session()
      |> maybe_broadcast_exhaustion()

    broadcast(state.id, {:agent_message, msg})

    # @-mentions of specific agents are broadcast unconditionally; the
    # Coordinator gates each one through `try_activate/2` and queues
    # any that exceed the budget. The Room used to do the gating here,
    # but that left parallel-mention fan-out unbounded — a single
    # response @-mentioning five agents would spawn five Tasks before
    # the budget could see any of them.
    agent_mentions = Enum.filter(mentions, &(&1 != "everyone" and &1 != "channel"))

    if agent_mentions != [] do
      broadcast(state.id, {:agent_mentions, state.id, sender.id, agent_mentions, content})
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
        pending_activations: [],
        in_progress: %{},
        active_sessions: 0,
        budget_exhausted_pending?: false,
        halted: true
    }

    broadcast(state.id, {:halted, state.id})
    reply_with_timeout(:ok, state)
  end

  def handle_call(:continue, _from, state) do
    pending = state.pending_activations

    state = %{
      state
      | activations_remaining: state.activation_budget,
        current_round_responded: MapSet.new(),
        status: :active,
        pending_activations: [],
        budget_broadcast?: false,
        budget_exhausted_pending?: false,
        halted: false
    }

    broadcast(state.id, {:continued, replayed: length(pending)})

    # Replay queued activations that were deferred when budget exhausted.
    # Each fires as :reactivate — the Coordinator handler treats it as
    # a fresh activation and re-checks try_activate against the
    # newly-reset budget.
    Enum.each(pending, fn {agent_id, opts} ->
      broadcast(state.id, {:reactivate, state.id, agent_id, opts})
    end)

    reply_with_timeout(:ok, state)
  end

  def handle_call({:join, agent_id}, _from, state) do
    agents = MapSet.put(state.agents, agent_id)
    # Recompute the cap so a new agent can participate in this turn,
    # but leave activations_remaining alone — slots already spent
    # stay spent.
    state = %{state | agents: agents, activation_budget: budget_for(%{state | agents: agents})}
    broadcast(state.id, {:agent_joined, agent_id})
    {:reply, :ok, state}
  end

  def handle_call({:leave, agent_id}, _from, state) do
    agents = MapSet.delete(state.agents, agent_id)
    state = %{state | agents: agents, activation_budget: budget_for(%{state | agents: agents})}
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
      activations_remaining: state.activations_remaining,
      activation_budget: state.activation_budget,
      pending_activations: length(state.pending_activations),
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
