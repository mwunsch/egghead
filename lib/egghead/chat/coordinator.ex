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
    defstruct [:id, :name, :model, :capabilities, :tags, :disposition]
  end

  defmodule State do
    @moduledoc false
    # `pending_transitions` keys an agent_id to one of:
    #   - `{:reload, prev_info}` — a record edit landed; expect a fresh
    #     `:terminated`+`:started` lifecycle pair. The :terminated should
    #     swallow; the :started narrates the diff.
    #   - `{:rename, prev_id, prev_info}` — same, but the id changed; the
    #     :started narrates "<old> became <new>".
    #   - `:demote` — agent class dropped; on :terminated narrate
    #     "<name> is no longer an agent" and unregister.
    #   - `:remove` — record was deleted; on :terminated narrate
    #     "<name>'s record was removed" and unregister.
    defstruct agents: %{},
              rooms: MapSet.new(),
              handoffs_in_progress: MapSet.new(),
              pending_transitions: %{},
              corpus: %{}
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
    Egghead.Node.cast(server, {:register_agent, agent_id, metadata})
  end

  @doc """
  Unregister an agent.
  """
  @spec unregister_agent(GenServer.server(), String.t()) :: :ok
  def unregister_agent(server \\ __MODULE__, agent_id) do
    Egghead.Node.cast(server, {:unregister_agent, agent_id})
  end

  @doc """
  Subscribe the coordinator to a room's events.
  """
  @spec watch_room(GenServer.server(), String.t()) :: :ok
  def watch_room(server \\ __MODULE__, room_id) do
    # Synchronous: the caller often immediately sends a message to
    # the room after this returns. If watch_room were a cast the
    # Coordinator could still be processing queued work when the
    # first user_message fires, which means it hasn't subscribed to
    # the room topic yet and silently misses the event (no agents
    # activate, room idle-times out 5 min later). A call blocks
    # until subscription is actually set up.
    Egghead.Node.call(server, {:watch_room, room_id})
  end

  @doc """
  Get the list of registered agents.
  """
  @spec list_registered(GenServer.server()) :: [map()]
  def list_registered(server \\ __MODULE__) do
    Egghead.Node.call(server, :list_registered)
  end

  @doc """
  Look up an agent's display name. Falls back to the id basename if
  the agent isn't registered with the Coordinator (rare, but possible
  during early startup or after a crash-restart).
  """
  @spec display_name(GenServer.server(), String.t()) :: String.t()
  def display_name(server \\ __MODULE__, agent_id) do
    try do
      Egghead.Node.call(server, {:display_name, agent_id})
    catch
      :exit, _ -> agent_id |> String.split("/") |> List.last() |> String.capitalize()
    end
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    # Subscribe to agent lifecycle events so we can announce
    # restarts and terminations into the rooms we're watching.
    Phoenix.PubSub.subscribe(@pubsub, Egghead.Agent.lifecycle_topic())

    # Subscribe to record-store events so we can pre-empt the
    # lifecycle pair with a "reloading…" hint and compute a diff
    # before the agent's register_agent cast overwrites the prior
    # AgentInfo. See `handle_info({:agent_record_changed, ...})`.
    Phoenix.PubSub.subscribe(@pubsub, Egghead.RecordStore.records_topic())

    # Rebuild state from whatever agents and rooms are already running.
    # On initial boot this is a no-op (supervision order starts us
    # before Agent.Supervisor), but after a crash-restart the agent
    # processes and rooms are still alive — we need to pick them back
    # up so activation works without waiting for agents to re-register.
    state =
      %State{}
      |> rebuild_from_running_agents()
      |> rebuild_room_subscriptions()

    if map_size(state.agents) > 0 or MapSet.size(state.rooms) > 0 do
      Logger.info(
        "Coordinator: rebuilt state from #{map_size(state.agents)} agent(s), " <>
          "#{MapSet.size(state.rooms)} room(s)"
      )
    end

    {:ok, state}
  end

  @impl true
  def handle_cast({:register_agent, agent_id, metadata}, state) do
    info = %AgentInfo{
      id: agent_id,
      name: metadata[:name] || agent_id,
      model: metadata[:model],
      capabilities: metadata[:capabilities] || [],
      tags: metadata[:tags] || [],
      disposition: metadata[:disposition] || ""
    }

    agents = Map.put(state.agents, agent_id, info)
    corpus = Egghead.Chat.Relevance.build_corpus(agents)
    state = %{state | agents: agents, corpus: corpus}
    broadcast_roster_changed(state)
    Logger.debug("Coordinator: registered agent #{agent_id}")
    {:noreply, state}
  end

  def handle_cast({:unregister_agent, agent_id}, state) do
    agents = Map.delete(state.agents, agent_id)
    corpus = Egghead.Chat.Relevance.build_corpus(agents)
    state = %{state | agents: agents, corpus: corpus}
    broadcast_roster_changed(state)
    Logger.debug("Coordinator: unregistered agent #{agent_id}")
    {:noreply, state}
  end

  def handle_call({:watch_room, room_id}, _from, state) do
    Phoenix.PubSub.subscribe(@pubsub, Room.topic(room_id))
    state = %{state | rooms: MapSet.put(state.rooms, room_id)}
    Logger.info("Coordinator: watching room #{room_id}")
    {:reply, :ok, state}
  end

  def handle_call({:display_name, agent_id}, _from, state) do
    {:reply, agent_display_name(state, agent_id), state}
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
      # `state.agents` is a global registry — agents can be joined to
      # different rooms. Scope candidates to those actually joined to
      # this room, otherwise an eval run (or any bespoke-roster room)
      # pulls in every agent the process knows about, regardless of
      # whether they were invited.
      candidates = scope_to_room(state.agents, room_id)
      agents_to_activate = tier1_filter(msg, candidates)

      if agents_to_activate == [] do
        Logger.warning("Coordinator: no agents registered, nobody to activate")
      end

      activate(agents_to_activate, msg, room_id, state)
    else
      Logger.warning("Coordinator: received message but not watching any rooms")
    end

    {:noreply, state}
  end

  def handle_info({:agent_mentions, room_id, from_agent, mentioned_ids, _content}, state) do
    muted_set = room_muted_set(room_id)

    # Peer-agent @-mentions do NOT bypass mute. The mute was the
    # user's choice about what *they* want to hear; an agent
    # referencing a muted peer in the transcript must not override
    # that decision. Only a user's direct mention (handled in
    # `activate/4`) wakes a muted agent.
    agents =
      mentioned_ids
      |> Enum.flat_map(fn id -> find_agent(state.agents, id) end)
      |> Enum.reject(&MapSet.member?(muted_set, &1.id))

    if agents != [] do
      Logger.info("Coordinator: #{from_agent} mentioned #{Enum.map_join(agents, ", ", & &1.id)}")

      broadcast_activation(room_id, length(agents))

      # The mention content is already in each activated agent's
      # state.history via its broadcast subscription. The activation
      # call is a pure "take your turn" signal — an empty message
      # tells do_prompt not to append another user turn.
      Enum.each(agents, fn agent_info ->
        Task.Supervisor.start_child(Egghead.Tool.TaskSupervisor, fn ->
          prompt_agent_in_room(agent_info.id, room_id, "")
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

  def handle_info({:halted, room_id}, state) do
    Logger.info("Coordinator: room #{room_id} halted")

    # Drop any outstanding handoff markers for this room. In-flight
    # Tasks under the room's Sessions abort themselves on the same
    # broadcast — Coordinator just clears its own bookkeeping so the
    # next user message starts from a clean slate.
    handoffs =
      state.handoffs_in_progress
      |> Enum.reject(fn {_agent_id, rid} -> rid == room_id end)
      |> MapSet.new()

    {:noreply, %{state | handoffs_in_progress: handoffs}}
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
  def handle_info({:system_notice, _text}, state), do: {:noreply, state}

  def handle_info({:agent_lifecycle, event, agent_id, reason, info}, state) do
    handle_lifecycle(event, agent_id, reason, info, state)
  end

  # Pre-empt the lifecycle handler with a "reloading…" hint when the
  # record store classifies a write as a change to an agent record.
  # Stashing happens here, narration of the diff happens when the
  # subsequent `:started` lifecycle event lands. Crucial that the
  # snapshot is captured BEFORE the agent's `register_agent` cast
  # overwrites state.agents[agent_id] with the new metadata.
  def handle_info({:agent_record_changed, change}, state) do
    Logger.info("Coordinator: received :agent_record_changed #{inspect(change, limit: 3)}")
    handle_record_change(change, state)
  end

  # Older single-tag record events fired by RecordStore for non-agent
  # records. Ignore — this handler exists only to silence the catch-all
  # debug log for routine record edits.
  def handle_info({:record_changed, _id_or_nil}, state), do: {:noreply, state}

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

  def handle_info({:room_stopped, room_id}, state) do
    {:noreply, %{state | rooms: MapSet.delete(state.rooms, room_id)}}
  end

  # Catch-all: every new PubSub event type flows here first until a
  # matching clause is added above. Don't crash the Coordinator on
  # unknown messages — it's subscribed to every room topic and to
  # agent lifecycle events; a missing clause would cascade-restart
  # the whole agent layer. Log and ignore instead.
  def handle_info(msg, state) do
    Logger.debug("Coordinator: ignoring unknown message #{inspect(msg, limit: 5)}")
    {:noreply, state}
  end

  # --- Lifecycle + record-change narration ---

  # Hint events from RecordStore.apply_agent_transition. We snapshot
  # the prior AgentInfo here (before the agent's restart fires its
  # register_agent cast) so the subsequent :started can narrate the
  # diff. For demote/remove there's no follow-up :started — the
  # narration runs at :terminated time.
  defp handle_record_change({:reloaded, %{id: id} = _record}, state) do
    prev_info = Map.get(state.agents, id)

    # Always identify by agent id, not display name. The user may
    # have edited the title in this very save — the old name would
    # mislead, the new name isn't loaded yet, the id is stable.
    announce_to_rooms(state, "#{id} reloading…")

    state = %{
      state
      | pending_transitions: Map.put(state.pending_transitions, id, {:reload, prev_info})
    }

    {:noreply, state}
  end

  defp handle_record_change({:renamed, prev_id, %{id: new_id}}, state) do
    prev_info = Map.get(state.agents, prev_id)

    # Drop the old AgentInfo immediately; the new one will land via
    # refresh_agent_info on the followup :started lifecycle. No
    # "reloading…" announcement — the `<old> became <new>` line
    # carries enough.
    agents = Map.delete(state.agents, prev_id)
    corpus = Egghead.Chat.Relevance.build_corpus(agents)

    state = %{
      state
      | agents: agents,
        corpus: corpus,
        pending_transitions:
          Map.put(state.pending_transitions, new_id, {:rename, prev_id, prev_info})
    }

    # Mirror the rename in each watched room's roster: anywhere
    # prev_id was joined, swap in new_id so activation continues.
    swap_in_watched_rooms(state, prev_id, new_id)

    broadcast_roster_changed(state)
    {:noreply, state}
  end

  defp handle_record_change({:demoted, prev_id}, state) do
    state = %{state | pending_transitions: Map.put(state.pending_transitions, prev_id, :demote)}
    {:noreply, state}
  end

  defp handle_record_change({:removed, prev_id}, state) do
    state = %{state | pending_transitions: Map.put(state.pending_transitions, prev_id, :remove)}
    {:noreply, state}
  end

  defp handle_record_change({:promoted, %{id: id} = _record}, state) do
    # New agents fold into every watched room. Same semantic as
    # `create_room/1`, which joins all existing agents at room
    # creation — agents created LATER need to be added explicitly
    # somewhere, and the Coordinator is the only piece that knows
    # about all live rooms.
    join_in_watched_rooms(state, id)

    # Stash a :promote marker so the followup :started lifecycle
    # narrates with the agent id (`agents/kiwi joined`) rather than
    # the display name. Record-driven transitions identify by id.
    state = %{state | pending_transitions: Map.put(state.pending_transitions, id, :promote)}
    {:noreply, state}
  end

  # Translate global agent lifecycle events into per-room system
  # notices, coalescing with any record-change hint stashed by
  # handle_record_change. The :started broadcast carries the
  # agent's identity payload inline — populating AgentInfo from
  # the message itself, with no round-trip back to a possibly-busy
  # agent process. The pull path (refresh_agent_info) survives as
  # a fallback for messages without payload (legacy senders) and
  # for crash-restart resync (rebuild_from_running_agents).
  defp handle_lifecycle(:started, agent_id, _reason, info, state) do
    {pending, remaining} = Map.pop(state.pending_transitions, agent_id)
    state = %{state | pending_transitions: remaining}

    state =
      case info do
        %{} = payload -> apply_agent_info(state, agent_id, payload)
        _ -> refresh_agent_info(state, agent_id)
      end

    broadcast_roster_changed(state)

    case pending do
      {:reload, prev_info} ->
        announce_to_rooms(state, reload_text(prev_info, agent_id, state))

      {:rename, prev_id, prev_info} ->
        announce_to_rooms(state, rename_text(prev_id, prev_info, agent_id, state))

      :promote ->
        # Record-driven join: identify by id for stability.
        announce_to_rooms(state, "#{agent_id} joined")

      _ ->
        # Lifecycle-only :started (boot, supervisor restart) — fine
        # to use the live display name; identity is what's relevant.
        announce_to_rooms(state, "#{agent_display_name(state, agent_id)} joined")
    end

    {:noreply, state}
  end

  defp handle_lifecycle(:terminated, agent_id, reason, _info, state) do
    # Rename markers are keyed by the NEW id (the side that fires
    # :started), so a rename-source :terminated has no direct match.
    # Detect that case by walking pending_transitions for a :rename
    # whose source matches us.
    rename_source? =
      Enum.any?(state.pending_transitions, fn
        {_, {:rename, ^agent_id, _}} -> true
        _ -> false
      end)

    cond do
      rename_source? ->
        # Swallow; the matching :started for the new id will narrate.
        {:noreply, state}

      pending = Map.get(state.pending_transitions, agent_id) ->
        case pending do
          {:reload, _} ->
            # Leave the marker in place — :started narrates the diff.
            {:noreply, state}

          :demote ->
            announce_to_rooms(state, "#{agent_id} is no longer an agent")
            unregister_agent(self(), agent_id)

            {:noreply,
             %{state | pending_transitions: Map.delete(state.pending_transitions, agent_id)}}

          :remove ->
            announce_to_rooms(state, "#{agent_id}'s record was removed")
            unregister_agent(self(), agent_id)

            {:noreply,
             %{state | pending_transitions: Map.delete(state.pending_transitions, agent_id)}}

          _ ->
            do_terminate(agent_id, reason, state)
        end

      true ->
        do_terminate(agent_id, reason, state)
    end
  end

  # Fire-and-forget room joins for a newly-promoted agent — one
  # task per watched room. Off-process so the Coordinator's mailbox
  # doesn't block on Room.call latencies.
  defp join_in_watched_rooms(state, agent_id) do
    for room_id <- state.rooms do
      run_off_process(fn ->
        try do
          Room.join(room_id, agent_id)
        catch
          _, _ -> :ok
        end
      end)
    end

    :ok
  end

  # For a rename: drop the old id, add the new id, only in rooms
  # where the old id was actually joined. Avoids over-joining the
  # new id into bespoke-roster rooms (eval, etc.) that didn't have
  # the old one.
  defp swap_in_watched_rooms(state, prev_id, new_id) do
    for room_id <- state.rooms do
      run_off_process(fn ->
        try do
          %{agents: joined} = Room.get_state(room_id)

          if prev_id in joined do
            Room.leave(room_id, prev_id)
            Room.join(room_id, new_id)
          end
        catch
          _, _ -> :ok
        end
      end)
    end

    :ok
  end

  # Run `fun` under the application's Task.Supervisor when it's
  # available (production); fall back to bare `Task.start/1` in
  # contexts that don't have it (focused unit tests, escripts).
  defp run_off_process(fun) do
    if Process.whereis(Egghead.Tool.TaskSupervisor) do
      Task.Supervisor.start_child(Egghead.Tool.TaskSupervisor, fun)
    else
      Task.start(fun)
    end
  end

  # Build an AgentInfo from the payload the agent broadcast inline
  # with its `:started` lifecycle event. Race-free — no round-trip
  # to a possibly-busy agent process.
  defp apply_agent_info(state, agent_id, payload) when is_map(payload) do
    info = %AgentInfo{
      id: agent_id,
      name: Map.get(payload, :name) || agent_id,
      model: Map.get(payload, :model),
      capabilities: Map.get(payload, :capabilities) || [],
      tags: Map.get(payload, :tags) || [],
      disposition: Map.get(payload, :disposition) || ""
    }

    agents = Map.put(state.agents, agent_id, info)
    corpus = Egghead.Chat.Relevance.build_corpus(agents)
    %{state | agents: agents, corpus: corpus}
  end

  # Read AgentInfo from the live process by registered name. If the
  # process is gone or the read fails, leave state.agents unchanged.
  # Used as a fallback when no inline payload is available — e.g.
  # crash-restart resync via rebuild_from_running_agents, or test
  # senders that fire bare lifecycle messages.
  defp refresh_agent_info(state, agent_id) do
    name = Egghead.Agent.agent_name(agent_id)

    case GenServer.whereis(name) do
      nil ->
        state

      pid ->
        case safe_agent_info(pid) do
          nil ->
            state

          info ->
            agents = Map.put(state.agents, agent_id, info)
            corpus = Egghead.Chat.Relevance.build_corpus(agents)
            %{state | agents: agents, corpus: corpus}
        end
    end
  end

  defp do_terminate(agent_id, reason, state) do
    display = agent_display_name(state, agent_id)

    text =
      case reason do
        :normal -> "#{display} left"
        :shutdown -> "#{display} left"
        {:shutdown, _} -> "#{display} left"
        other -> "#{display} crashed: #{format_reason(other)}"
      end

    announce_to_rooms(state, text)
    unregister_agent(self(), agent_id)
    {:noreply, state}
  end

  defp announce_to_rooms(state, text) do
    rooms = MapSet.to_list(state.rooms)

    Logger.info(
      "Coordinator: announcing #{inspect(text)} to #{length(rooms)} room(s): #{inspect(rooms)}"
    )

    for room_id <- rooms, do: broadcast_system_notice(room_id, text)
    :ok
  end

  defp broadcast_roster_changed(state) do
    for room_id <- state.rooms do
      Phoenix.PubSub.broadcast(@pubsub, Room.topic(room_id), {:agent_roster_changed})
    end

    :ok
  end

  # Diff between the prior AgentInfo (captured at hint time) and the
  # current state.agents entry (already refreshed from the new process
  # in handle_lifecycle(:started, ...)). Empty diff → no parenthetical.
  # Uses agent id, not display name — see handle_record_change.
  defp reload_text(nil, agent_id, _state), do: "#{agent_id} reloaded"

  defp reload_text(%AgentInfo{} = prev, agent_id, state) do
    new_info = Map.get(state.agents, agent_id)
    parts = diff_parts_with_title(prev, new_info)

    case parts do
      [] -> "#{agent_id} reloaded"
      _ -> "#{agent_id} reloaded (#{Enum.join(parts, "; ")})"
    end
  end

  defp rename_text(prev_id, _prev_info, new_id, _state) do
    "#{prev_id} became #{new_id}"
  end

  # Like diff_parts/2 but also surfaces a title (display-name) change,
  # since the rest of the notice now identifies the agent by id.
  defp diff_parts_with_title(%AgentInfo{} = prev, %AgentInfo{} = new) do
    diff_parts(prev, new) |> maybe_add_diff("title", prev.name, new.name)
  end

  defp diff_parts_with_title(prev, _), do: diff_parts(prev, nil)

  defp diff_parts(_prev, nil), do: []

  defp diff_parts(%AgentInfo{} = prev, %AgentInfo{} = new) do
    []
    |> maybe_add_diff("model", prev.model, new.model)
    |> maybe_add_caps_diff(prev.capabilities, new.capabilities)
  end

  defp maybe_add_diff(parts, _label, same, same), do: parts

  defp maybe_add_diff(parts, label, prev, new),
    do: parts ++ ["#{label}: #{prev || "?"} → #{new || "?"}"]

  defp maybe_add_caps_diff(parts, prev_caps, new_caps) do
    prev_keys = caps_keys(prev_caps)
    new_keys = caps_keys(new_caps)
    added = MapSet.difference(new_keys, prev_keys) |> Enum.sort()
    removed = MapSet.difference(prev_keys, new_keys) |> Enum.sort()

    case {added, removed} do
      {[], []} ->
        parts

      _ ->
        bits =
          Enum.map(added, &"+#{&1}") ++ Enum.map(removed, &"−#{&1}")

        parts ++ ["capabilities: #{Enum.join(bits, ", ")}"]
    end
  end

  defp caps_keys(nil), do: MapSet.new()

  defp caps_keys(caps) when is_list(caps) do
    caps
    |> Enum.map(fn
      %Egghead.Capability.Grant{resource: r, verb: v} -> "#{r}.#{v}"
      other -> to_string(other)
    end)
    |> MapSet.new()
  end

  defp caps_keys(_), do: MapSet.new()

  # --- Tier 1: Structural filter (zero tokens) ---

  # Returns the subset of `all_agents` that are currently joined to
  # `room_id`. Falls back to the full set on lookup failure (safer to
  # be noisy than to silently activate nobody if the room crashed).
  @doc false
  def scope_to_room(all_agents, room_id) do
    try do
      case Egghead.Chat.Room.get_state(room_id) do
        %{agents: joined} when is_list(joined) ->
          wanted = MapSet.new(joined)
          Map.filter(all_agents, fn {id, _info} -> MapSet.member?(wanted, id) end)

        _ ->
          all_agents
      end
    catch
      _, _ -> all_agents
    end
  end

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

  defp room_muted_set(room_id) do
    try do
      room_id |> Egghead.Chat.Room.muted() |> MapSet.new()
    catch
      _, _ -> MapSet.new()
    end
  end

  # Resolve raw `@name` tokens from a user message to canonical
  # agent ids. Accepts full id, basename, or display name —
  # matching `find_agent/2`. Broadcast pseudo-mentions
  # (`everyone`/`channel`/`jam`) are excluded: those are
  # room-wide addressing, not a specific-agent summon, and
  # must not override mute.
  defp summoned_ids(agents, mentions) do
    names =
      mentions
      |> Enum.reject(&(&1 in ["everyone", "channel", "jam"]))
      |> Enum.map(&String.downcase/1)

    agents
    |> Enum.filter(fn info ->
      lower_id = String.downcase(info.id)
      basename = info.id |> String.split("/") |> List.last() |> String.downcase()
      lower_display = String.downcase(info.name || "")

      Enum.any?(names, fn n ->
        n == lower_id or n == basename or n == lower_display
      end)
    end)
    |> Enum.map(& &1.id)
    |> MapSet.new()
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

    # Muted agents stay silent — with one escape hatch: if the user
    # directly @-mentions them in *this* message, treat it as a
    # deliberate one-turn override. Peer-agent mentions and
    # `@everyone` broadcasts do NOT bypass mute; only a user typing
    # `@agent_id` does. The mute itself stays in effect — next turn
    # without a user mention and the agent's silent again.
    user_summoned =
      if msg.sender.type == :user,
        do: summoned_ids(agents, mentions),
        else: MapSet.new()

    agents_to_prompt =
      agents
      |> Enum.reject(fn info ->
        handoff? = MapSet.member?(state.handoffs_in_progress, {info.id, room_id})
        muted? = MapSet.member?(muted_set, info.id)
        summoned? = MapSet.member?(user_summoned, info.id)

        handoff? or (muted? and not summoned?)
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
          Task.Supervisor.start_child(Egghead.Tool.TaskSupervisor, fn ->
            prompt_agent_in_room(agent_info.id, room_id, "", activation: :jam)
          end)
        end)

      :huddle ->
        # Serial roll-call. Every agent must respond; `/pass` is not allowed
        # (the Session prompt enforces this via the `:huddle` addendum).
        Task.Supervisor.start_child(Egghead.Tool.TaskSupervisor, fn ->
          Enum.each(agents_to_prompt, fn agent_info ->
            broadcast_activation(room_id, 1)
            prompt_agent_in_room(agent_info.id, room_id, "", activation: :huddle)
          end)
        end)

      :normal when room_mode == :staggered and length(agents_to_prompt) > 1 ->
        # Staggered (opt-in): each agent runs in its own Task. A coordinator
        # Task subscribes to PubSub and spawns agents with stagger delays.
        Task.Supervisor.start_child(Egghead.Tool.TaskSupervisor, fn ->
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
            Task.Supervisor.start_child(Egghead.Tool.TaskSupervisor, fn ->
              prompt_agent_in_room(agent_info.id, room_id, "", activation: :normal)
            end)
          end)
        end)

      :normal ->
        # Serial (default): strict A-finishes-then-B in one Task
        Task.Supervisor.start_child(Egghead.Tool.TaskSupervisor, fn ->
          Enum.each(agents_to_prompt, fn agent_info ->
            broadcast_activation(room_id, 1)
            prompt_agent_in_room(agent_info.id, room_id, "", activation: :normal)
          end)
        end)
    end
  end

  # The Coordinator's only job: pass the message and room context to the agent.
  # The agent handles its own context building, usage tracking, and handoff.
  defp prompt_agent_in_room(agent_id, room_id, message, opts \\ []) do
    activation = Keyword.get(opts, :activation, :normal)

    case run_agent_attempt(agent_id, room_id, message, activation) do
      {:ok, text, usage, tool_calls} ->
        handle_agent_result(agent_id, room_id, text, usage, tool_calls, activation)

      # Halt is intentional, not an error. Don't surface the pass flavor
      # line either — the room's status bar already tells the user.
      {:error, :halted} ->
        Room.clear_in_progress(room_id, agent_id)

      {:error, reason} ->
        Logger.warning("Coordinator: agent #{agent_id} failed: #{inspect(reason)}")
        broadcast_agent_error(room_id, agent_id, reason)
        Room.clear_in_progress(room_id, agent_id)
        broadcast_pass(room_id, agent_id)
    end
  end

  # One LLM attempt: set up streaming accumulator, call the agent, return
  # the final text + usage. The in-progress buffer is read by the caller
  # via `Room.get_in_progress/2`.
  #
  # Streaming is RAW: every text delta is broadcast immediately to
  # PubSub subscribers. Display-side buffering (e.g. paragraph batching
  # for the TUI's IRC view) belongs to the consumer, not here. Other
  # watchers — RoomLogger, MCP egghead_chat, future Phoenix Channels —
  # need access to the unbuffered token stream.
  #
  # We still need a per-call cumulative accumulator so we can push the
  # running total to Room.streaming_update (read by the /pass rescue
  # path and by tools that ask "what has this agent said so far?").
  # This MUST live in its own process: on_chunk runs inside the Session
  # GenServer, not in this Task — so the process dictionary cannot be
  # used here without leaking state across sequential prompts to the
  # same Session and corrupting later messages with text from earlier
  # turns.
  defp run_agent_attempt(agent_id, room_id, message, activation) do
    transcript = Room.get_transcript(room_id)
    room_state = Room.get_state(room_id)

    # The room is the source of truth for halt. A Task can spawn between
    # the moment the user requests halt and the moment {:halted, _}
    # reaches subscribed Sessions — this catches that race before we
    # spend tokens on the LLM call.
    cond do
      Map.get(room_state, :halted, false) ->
        {:error, :halted}

      true ->
        run_llm_call(agent_id, room_id, message, activation, transcript, room_state)
    end
  end

  defp run_llm_call(agent_id, room_id, message, activation, transcript, room_state) do
    room_context = %{
      id: room_id,
      transcript: transcript,
      agents: room_state.agents,
      activation: activation
    }

    {:ok, buffer_pid} = Agent.start_link(fn -> "" end)

    # Belt-and-suspenders: ensure no stale in_progress text from a
    # prior call lingers when this turn begins. Without this, even a
    # transient bug in the accumulator could cause the /pass rescue
    # path to commit text from a previous turn.
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
      {:ok, %Egghead.Agent.Response{text: text, usage: usage, tool_calls: tool_calls}} ->
        {:ok, text, usage, tool_calls || []}

      {:ok, %{text: text, usage: usage} = plain} ->
        # Fallback for callers that return a plain map instead of
        # the Response struct (e.g. future test doubles). Maps
        # support Access.
        {:ok, text, usage, Map.get(plain, :tool_calls, [])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Inspect the attempt's result and decide what to commit to the
  # transcript. Three cases:
  # - agent streamed substance during tool rounds then said /pass: rescue
  # - agent said /pass in huddle mode: re-prompt once, then neutral
  #   acknowledgment fallback (huddle forbids /pass by design)
  # - agent said /pass normally: commit the pass
  # - agent said something substantive: commit it
  defp handle_agent_result(agent_id, room_id, text, usage, tool_calls, activation) do
    pass? = pass_response?(text)
    in_progress = Room.get_in_progress(room_id, agent_id)

    cond do
      pass? and has_substantive_content?(in_progress) ->
        Logger.debug("Coordinator: #{agent_id} streamed content, committing despite /pass")

        Room.agent_respond(
          room_id,
          agent_id,
          decorate_with_tool_log(String.trim(in_progress), tool_calls),
          usage: usage
        )

      pass? and activation == :huddle ->
        Logger.warning("Coordinator: #{agent_id} passed in huddle mode — re-prompting once")
        retry_huddle_pass(agent_id, room_id)

      pass? ->
        Logger.debug("Coordinator: #{agent_id} passed (nothing to add)")
        # Room.agent_pass commits `/pass` to transcript AND broadcasts
        # :agent_passed (in-progress is cleared inside the handler).
        Room.agent_pass(room_id, agent_id)

      true ->
        Room.agent_respond(
          room_id,
          agent_id,
          decorate_with_tool_log(text, tool_calls),
          usage: usage
        )
    end
  end

  # Prepend a terse summary of any tool errors / denials to the
  # message body so they land in the saved transcript (Judge +
  # downstream agents can see what was attempted) and render in the
  # TUI / web / CLI without special-case handling. Successful tool
  # calls are already evidenced by their output in the text — we
  # only surface the failures here. No-op when the tool log is
  # empty or every call succeeded.
  @doc false
  def decorate_with_tool_log_for_test(text, tool_calls) do
    decorate_with_tool_log(text, tool_calls)
  end

  defp decorate_with_tool_log(text, []), do: text
  defp decorate_with_tool_log(text, nil), do: text

  defp decorate_with_tool_log(text, tool_calls) when is_list(tool_calls) do
    failed =
      Enum.filter(tool_calls, fn call ->
        Map.get(call, :error, false) == true
      end)

    case failed do
      [] ->
        text

      entries ->
        summary =
          entries
          |> Enum.map(&format_tool_failure/1)
          |> Enum.join("\n")

        "**Tool errors:**\n\n```\n#{summary}\n```\n\n---\n\n#{text}"
    end
  end

  defp format_tool_failure(%{name: name, input: input, result: result}) do
    # Trim long inputs so the transcript stays readable.
    compact_input =
      input
      |> inspect(limit: 3, printable_limit: 120)
      |> String.slice(0, 200)

    compact_result =
      result
      |> to_string()
      |> String.replace("\n", " ")
      |> String.slice(0, 300)

    "#{name}(#{compact_input}) → #{compact_result}"
  end

  defp format_tool_failure(other), do: inspect(other)

  # Huddle mode forbids /pass but agents still try. Re-prompt once with
  # a stronger nudge. If the retry is also a pass, accept it — we've
  # applied the social pressure huddle is meant to create, but we won't
  # force a dishonest contribution. The /pass renders atmospherically
  # via PassActions (e.g. "Scout shuffles notes, finds nothing new"),
  # which reads cleaner than a clinical "(no additional input)" line.
  defp retry_huddle_pass(agent_id, room_id) do
    nudge =
      "You passed in huddle mode, which is not allowed. " <>
        "Offer one honest line — agreement, a reservation, a question, " <>
        "or something adjacent you noticed. Do not pass."

    case run_agent_attempt(agent_id, room_id, nudge, :huddle) do
      {:ok, text, usage, tool_calls} ->
        pass? = pass_response?(text)
        in_progress = Room.get_in_progress(room_id, agent_id)

        cond do
          pass? and has_substantive_content?(in_progress) ->
            Room.agent_respond(
              room_id,
              agent_id,
              decorate_with_tool_log(String.trim(in_progress), tool_calls),
              usage: usage
            )

          pass? ->
            Logger.debug("Coordinator: #{agent_id} passed again in huddle — accepting the yield")

            Room.agent_pass(room_id, agent_id)

          true ->
            Room.agent_respond(
              room_id,
              agent_id,
              decorate_with_tool_log(text, tool_calls),
              usage: usage
            )
        end

      {:error, :halted} ->
        Room.clear_in_progress(room_id, agent_id)

      {:error, reason} ->
        Logger.warning("Coordinator: #{agent_id} huddle retry failed: #{inspect(reason)}")

        broadcast_agent_error(room_id, agent_id, reason)
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

  # Trim a terminate or error reason for display in chat. Erlang exit
  # reasons can be deeply nested; we keep enough text for the actual
  # diagnostic (provider error messages, etc.) but cap total length so
  # runaway stack traces don't flood the transcript.
  @max_reason_chars 400

  defp format_reason(reason) when is_binary(reason) do
    if String.length(reason) > @max_reason_chars,
      do: String.slice(reason, 0, @max_reason_chars - 3) <> "...",
      else: reason
  end

  defp format_reason(reason) do
    full = inspect(reason, limit: 5, printable_limit: @max_reason_chars)

    if String.length(full) > @max_reason_chars,
      do: String.slice(full, 0, @max_reason_chars - 3) <> "...",
      else: full
  end

  defp agent_display_name(state, agent_id) do
    case Map.get(state.agents, agent_id) do
      %AgentInfo{name: name} -> name
      _ -> agent_id
    end
  end

  defp broadcast_system_notice(room_id, text) do
    Phoenix.PubSub.broadcast(@pubsub, Room.topic(room_id), {:system_notice, text})
  end

  # After a crash-restart, walk the live Agent.Supervisor children and
  # repopulate agent metadata. Defensive: on initial boot,
  # Agent.Supervisor hasn't started yet (we come up first under the
  # layer supervisor), so `whereis` returns nil and we no-op. Agents
  # will register normally as they start.
  defp rebuild_from_running_agents(state) do
    case GenServer.whereis(Egghead.Agent.Supervisor) do
      nil ->
        state

      _pid ->
        agents =
          Egghead.Agent.Supervisor
          |> DynamicSupervisor.which_children()
          |> Enum.reduce(%{}, fn {_, pid, _, _}, acc ->
            if is_pid(pid) and Process.alive?(pid) do
              case safe_agent_info(pid) do
                nil -> acc
                info -> Map.put(acc, info.id, info)
              end
            else
              acc
            end
          end)

        corpus = Egghead.Chat.Relevance.build_corpus(agents)
        %{state | agents: agents, corpus: corpus}
    end
  end

  defp safe_agent_info(pid) do
    try do
      case :sys.get_state(pid, 100) do
        %{id: id, name: name, capabilities: caps, tags: tags, disposition: disp} = s ->
          %AgentInfo{
            id: id,
            name: name,
            model: Map.get(s, :model),
            capabilities: caps,
            tags: tags,
            disposition: disp
          }

        _ ->
          nil
      end
    catch
      :exit, _ -> nil
    end
  end

  # Re-subscribe to every live room on restart. The `watch_room/1`
  # cast only fires once (from Egghead.create_room); after a crash
  # no one re-invokes it, so we have to rediscover rooms ourselves.
  defp rebuild_room_subscriptions(state) do
    try do
      Egghead.Chat.Room.list_ids()
      |> Enum.reduce(state, fn room_id, acc ->
        Phoenix.PubSub.subscribe(@pubsub, Room.topic(room_id))
        %{acc | rooms: MapSet.put(acc.rooms, room_id)}
      end)
    catch
      :exit, _ -> state
    end
  end

  # Visible error notice: an agent that was summoned but failed to
  # produce a response. Pairs with `broadcast_pass/2` (which commits
  # the transcript placeholder) so users see both "Scout errored: …"
  # and the atmospheric pass line, rather than just silence.
  defp broadcast_agent_error(room_id, agent_id, reason) do
    # Sync round-trip to the Coordinator GenServer to resolve the
    # agent's configured display name. The capitalized id basename
    # is a fallback when the Coordinator isn't reachable.
    display = display_name(__MODULE__, agent_id)
    broadcast_system_notice(room_id, "#{display} errored: #{format_reason(reason)}")
  end
end
