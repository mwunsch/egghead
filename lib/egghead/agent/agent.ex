defmodule Egghead.Agent do
  @moduledoc """
  An agent process backed by a record of class `:agent`.

  The agent holds identity (disposition, model, capabilities) and spawns
  per-room Session processes for conversation. Each room gets its own
  session so history doesn't bleed across rooms. A "default" session
  handles 1:1 prompts outside rooms.

  ## Agent Record Format

  ```markdown
  ---
  id: agents/scout
  class: agent
  model: claude-sonnet-4-6
  provider: anthropic
  capabilities: [records.read, records.create]
  thinking: enabled
  context_threshold: 0.70
  max_tokens: 4096
  temperature: 0.7
  ---

  You look for connections between records across different domains...
  ```
  """

  use GenServer

  require Logger

  alias Egghead.Agent.Session
  alias Egghead.LLM.Registry
  alias Egghead.Record.Agent, as: AgentProjection

  defmodule State do
    @moduledoc false

    defstruct [
      :id,
      :name,
      :disposition,
      :model,
      :capabilities,
      :sandbox,
      :thinking,
      :max_tokens,
      :temperature,
      :context_threshold,
      :context_window,
      tags: [],
      # %{room_id | :default => session_pid}
      sessions: %{}
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

  If `opts[:room]` is set, the prompt goes to a per-room session.
  Otherwise it goes to the default (1:1) session.
  """
  @spec prompt(String.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def prompt(agent_id, message, opts \\ []) do
    name = agent_name(agent_id)

    case whereis_node_aware(name) do
      nil -> {:error, :agent_not_found}
      _pid -> Egghead.Node.call(name, {:prompt, message, opts}, 300_000)
    end
  end

  @doc """
  Manually triggers a handoff on a session.

  With no opts or a string, hands off the default session.
  With `room_id: "room-id"`, hands off that room's session.
  """
  @spec handoff(String.t(), keyword() | String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def handoff(agent_id, opts \\ nil)

  def handoff(agent_id, opts) when is_list(opts) do
    name = agent_name(agent_id)

    case whereis_node_aware(name) do
      nil -> {:error, :agent_not_found}
      _pid -> Egghead.Node.call(name, {:handoff, opts}, 300_000)
    end
  end

  def handoff(agent_id, next_prompt) do
    handoff(agent_id, next_prompt: next_prompt)
  end

  @doc """
  Saves key insights from the current conversation to durable records
  without clearing the session.
  """
  @spec save(String.t()) :: {:ok, String.t()} | {:error, term()}
  def save(agent_id) do
    name = agent_name(agent_id)

    case whereis_node_aware(name) do
      nil -> {:error, :agent_not_found}
      _pid -> Egghead.Node.call(name, :save, 300_000)
    end
  end

  @doc """
  Drops the per-room session for `agent_id` in `room_id`. Stops the
  Session GenServer (if any) and removes its entry from the agent's
  sessions map. Used by `/kick` so a re-invited agent rebuilds its
  LLM context against the current room transcript instead of resuming
  with stale history.

  Returns `:ok` whether or not a session was present.
  """
  @spec drop_session(String.t(), String.t()) :: :ok | {:error, :agent_not_found}
  def drop_session(agent_id, room_id) when is_binary(room_id) do
    name = agent_name(agent_id)

    case whereis_node_aware(name) do
      nil -> {:error, :agent_not_found}
      _pid -> Egghead.Node.call(name, {:drop_session, room_id})
    end
  end

  @doc """
  Lists all running agents.
  """
  @spec list_agents() :: [map()]
  def list_agents do
    # When connected to a remote server, delegate the whole operation
    # since GenServer.whereis and :sys.get_state are node-local.
    case Egghead.Node.server_node() do
      nil -> list_agents_local()
      node -> :rpc.call(node, __MODULE__, :list_agents_local, [])
    end
  end

  @doc false
  def list_agents_local do
    store_agents =
      Egghead.search_by_class(:agent)
      |> Enum.map(& &1.id)

    all_ids = Enum.uniq(["index" | store_agents])

    all_ids
    |> Enum.filter(fn id -> agent_name(id) |> GenServer.whereis() != nil end)
    |> Enum.map(fn id ->
      name = agent_name(id)
      state = :sys.get_state(GenServer.whereis(name))

      # Aggregate usage across all sessions. `session_tokens` sums
      # (cumulative lifetime spend). `current_context_tokens` takes the
      # MAX across sessions — that's the worst-case current pressure on
      # this agent. "Total" would be misleading since each session has
      # its own context window.
      {total_usage, total_session_tokens, max_current_context, total_history} =
        state.sessions
        |> Map.values()
        |> Enum.reduce({%{input_tokens: 0, output_tokens: 0}, 0, 0, 0}, fn pid,
                                                                           {usage, stok, maxctx,
                                                                            hist} ->
          case safe_get_session_state(pid) do
            nil ->
              {usage, stok, maxctx, hist}

            session_state ->
              {
                %{
                  input_tokens: usage.input_tokens + session_state.usage.input_tokens,
                  output_tokens: usage.output_tokens + session_state.usage.output_tokens
                },
                stok + session_state.session_tokens,
                max(maxctx, session_state.current_context_tokens),
                hist + length(session_state.history)
              }
          end
        end)

      %{
        id: state.id,
        name: state.name,
        capabilities: state.capabilities,
        tags: state.tags,
        disposition: state.disposition,
        model: state.model,
        usage: total_usage,
        session_tokens: total_session_tokens,
        current_context_tokens: max_current_context,
        context_window: state.context_window,
        history_length: total_history
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

  # Node-aware process lookup. Checks remote node when connected.
  defp whereis_node_aware(name) do
    case Egghead.Node.server_node() do
      nil -> GenServer.whereis(name)
      node -> :rpc.call(node, GenServer, :whereis, [name])
    end
  end

  # --- GenServer callbacks ---

  @lifecycle_topic "agents:lifecycle"

  @impl true
  def init(record) do
    config = AgentProjection.from(record)

    state = %State{
      id: config.id,
      name: config.name,
      disposition: config.disposition,
      model: config.model,
      capabilities: config.capabilities,
      sandbox: config.sandbox,
      tags: config.tags,
      thinking: config.thinking,
      max_tokens: config.max_tokens,
      temperature: config.temperature,
      context_threshold: config.context_threshold,
      context_window: config.context_window
    }

    Logger.info(
      "Agent started: #{state.name} (#{state.id}) model=#{state.model} capabilities=#{inspect(state.capabilities)}"
    )

    warn_dangling_sandbox_grants(record, state)

    Process.flag(:trap_exit, true)

    # Frontmatter override wins — no point hitting the Registry if the
    # agent author declared their model's ceiling explicitly.
    if is_nil(state.context_window), do: send(self(), :fetch_model_info)

    # Push our identity card with the lifecycle broadcast — the
    # Coordinator reads it directly into its agent registry instead
    # of round-tripping back to us with `:sys.get_state`. The pull
    # path raced when the agent was busy in a follow-up handler
    # (e.g. :fetch_model_info) and the 100ms timeout silently
    # dropped the registration.
    broadcast_lifecycle(:started, state.id, nil, info_payload(state))

    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    # Fires on graceful stop and on supervisor restart (after a crash,
    # the supervisor stops the old process before starting a fresh
    # one). Doesn't fire on raw `:kill`, but neither do supervised
    # restarts use that. `trap_exit` (set in init) ensures we get
    # called on shutdown signals from the supervisor.
    broadcast_lifecycle(:terminated, state.id, reason, nil)
    :ok
  end

  defp broadcast_lifecycle(event, agent_id, reason, info) do
    Phoenix.PubSub.broadcast(
      Egghead.PubSub,
      @lifecycle_topic,
      {:agent_lifecycle, event, agent_id, reason, info}
    )
  end

  # Snapshot the fields the Coordinator caches in its AgentInfo
  # registry. Built from the live %State{} so a hot-reload always
  # broadcasts the post-edit values.
  defp info_payload(%State{} = state) do
    %{
      name: state.name,
      model: state.model,
      capabilities: state.capabilities,
      tags: state.tags,
      disposition: state.disposition
    }
  end

  @doc """
  PubSub topic for agent lifecycle events. Subscribe to receive
  `{:agent_lifecycle, event, agent_id, reason, info}` messages where
  event is `:started` or `:terminated`. `info` is a metadata payload
  on `:started` (used by the Coordinator to populate its registry
  without an extra round-trip), `nil` on `:terminated`.
  """
  def lifecycle_topic, do: @lifecycle_topic

  # Forward a long-running Session call via a supervised Task so the
  # Agent GenServer's mailbox keeps draining. The Task blocks on the
  # Session call, then uses `GenServer.reply/2` to respond to the
  # original caller — which is still waiting on its `GenServer.call`.
  # From the outside, nothing looks different; internally, the Agent
  # process isn't held hostage by the LLM's wall-clock.
  @impl true
  def handle_call({:prompt, message, opts}, from, state) do
    room = Keyword.get(opts, :room)
    room_id = if room, do: room.id
    room_pid = if room_id, do: room_process(room_id)

    {session_pid, state} = ensure_session(state, room_id, room_pid)
    forward_async(from, fn -> Session.prompt(session_pid, message, opts) end)
    {:noreply, state}
  end

  def handle_call({:handoff, opts}, from, state) when is_list(opts) do
    room_id = Keyword.get(opts, :room_id)
    session_key = room_id || :default

    case Map.get(state.sessions, session_key) do
      nil ->
        {:reply, {:error, :no_history}, state}

      pid ->
        forward_async(from, fn -> Session.handoff(pid, opts) end)
        {:noreply, state}
    end
  end

  def handle_call(:save, from, state) do
    case Map.get(state.sessions, :default) do
      nil ->
        {:reply, {:error, :no_history}, state}

      pid ->
        forward_async(from, fn -> Session.save(pid) end)
        {:noreply, state}
    end
  end

  def handle_call({:drop_session, room_id}, _from, state) do
    case Map.pop(state.sessions, room_id) do
      {nil, _} ->
        {:reply, :ok, state}

      {pid, sessions} ->
        # Best-effort stop. The :DOWN handler also cleans the map, but
        # popping eagerly avoids a race where a re-invite + prompt comes
        # in before the monitor message is delivered.
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end

        {:reply, :ok, %{state | sessions: sessions}}
    end
  end

  # Run `fun` in a supervised Task and forward its result to `from`
  # via GenServer.reply. Crashes are converted to `{:error, {:task_crashed, reason}}`
  # so the caller never hangs indefinitely. The Agent GenServer's
  # handle_call returned :noreply before this runs, so the caller is
  # still parked in GenServer.call waiting for a reply.
  defp forward_async(from, fun) do
    Task.Supervisor.start_child(Egghead.Tool.TaskSupervisor, fn ->
      result =
        try do
          fun.()
        rescue
          e -> {:error, {:task_crashed, Exception.message(e)}}
        catch
          :exit, reason -> {:error, {:task_crashed, reason}}
        end

      GenServer.reply(from, result)
    end)

    :ok
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

          {:ok, _info} ->
            fallback_context_window(state.model, state.name)

          {:error, reason} ->
            Logger.warning("Agent #{state.name}: could not fetch model info: #{inspect(reason)}")
            fallback_context_window(state.model, state.name)
        end
      catch
        :exit, _ ->
          Logger.warning("Agent #{state.name}: LLM Registry not available")
          fallback_context_window(state.model, state.name)
      end

    {:noreply, %{state | context_window: context_window}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # A session died — clean it from our sessions map
    sessions =
      state.sessions
      |> Enum.reject(fn {_key, session_pid} -> session_pid == pid end)
      |> Map.new()

    {:noreply, %{state | sessions: sessions}}
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    # A linked session exited (e.g. room was stopped). Clean up.
    sessions =
      state.sessions
      |> Enum.reject(fn {_key, session_pid} -> session_pid == pid end)
      |> Map.new()

    {:noreply, %{state | sessions: sessions}}
  end

  # --- Session management ---

  @max_sessions 10

  defp ensure_session(state, room_id, room_pid) do
    session_key = room_id || :default

    case Map.get(state.sessions, session_key) do
      nil ->
        if map_size(state.sessions) >= @max_sessions do
          Logger.warning("Agent #{state.name}: max sessions (#{@max_sessions}) reached")
          # Reuse the default session as fallback
          {Map.get(state.sessions, :default), state}
        else
          # Spawn a new session
          identity = build_identity(state)

          {:ok, pid} =
            Session.start_link(
              agent_id: state.id,
              room_id: room_id,
              identity: identity,
              room_pid: room_pid
            )

          Process.monitor(pid)
          state = %{state | sessions: Map.put(state.sessions, session_key, pid)}
          {pid, state}
        end

      pid ->
        if Process.alive?(pid) do
          {pid, state}
        else
          # Stale pid — respawn
          state = %{state | sessions: Map.delete(state.sessions, session_key)}
          ensure_session(state, room_id, room_pid)
        end
    end
  end

  defp warn_dangling_sandbox_grants(record, state) do
    raw = Map.get(record.meta || %{}, "capabilities")

    config_sandbox =
      case Egghead.Config.load() do
        {:ok, config} -> Egghead.Config.sandbox(config)
        _ -> nil
      end

    case Egghead.Capability.Validate.sandbox_warnings(raw, state.sandbox, config_sandbox) do
      [] -> :ok
      warnings -> Enum.each(warnings, fn w -> Logger.warning("Agent #{state.id}: #{w}") end)
    end
  end

  defp build_identity(state) do
    %{
      id: state.id,
      name: state.name,
      disposition: state.disposition,
      model: state.model,
      capabilities: state.capabilities,
      sandbox: state.sandbox,
      thinking: state.thinking,
      max_tokens: state.max_tokens,
      temperature: state.temperature,
      context_threshold: state.context_threshold,
      context_window: state.context_window
    }
  end

  defp room_process(room_id) do
    GenServer.whereis(:"egghead_room_#{room_id}")
  end

  defp safe_get_session_state(pid) do
    if Process.alive?(pid) do
      :sys.get_state(pid)
    else
      nil
    end
  rescue
    _ -> nil
  end

  # --- Helpers ---

  # When the provider API can't tell us, look up by model-family prefix.
  # Returns `nil` for genuinely unknown models so the TUI can render an
  # honest "unknown ceiling" instead of a fabricated number. Users on
  # exotic local models can set `context_window:` in agent frontmatter
  # to override everything.
  defp fallback_context_window(model, agent_name) do
    # The registry may prefix as `provider/model`; strip it before lookup.
    bare = model |> to_string() |> String.split("/", parts: 2) |> List.last()

    case Egghead.LLM.ModelMeta.context_window(bare) do
      nil ->
        Logger.warning(
          "Agent #{agent_name}: no context window for model #{model}; set `context_window:` in frontmatter to override"
        )

        nil

      ctx ->
        Logger.info("Agent #{agent_name}: fallback context window = #{ctx} tokens for #{model}")
        ctx
    end
  end
end
