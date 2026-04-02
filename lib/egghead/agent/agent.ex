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
  capabilities: [record_read, record_append, search]
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

  alias Egghead.LLM.Registry
  alias Egghead.Agent.Session

  @valid_capabilities ~w(record_read record_append record_modify search)
  @default_context_threshold 0.70

  defmodule State do
    @moduledoc false

    defstruct [
      :id,
      :name,
      :disposition,
      :model,
      :capabilities,
      :thinking,
      :max_tokens,
      :temperature,
      :context_threshold,
      :context_window,
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

    case GenServer.whereis(name) do
      nil -> {:error, :agent_not_found}
      _pid -> GenServer.call(name, {:prompt, message, opts}, 300_000)
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

    case GenServer.whereis(name) do
      nil -> {:error, :agent_not_found}
      _pid -> GenServer.call(name, {:handoff, opts}, 300_000)
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
      nil -> {:error, :agent_not_found}
      _pid -> GenServer.call(name, :usage)
    end
  end

  @doc """
  Lists all running agents.
  """
  @spec list_agents() :: [map()]
  def list_agents do
    store_agents =
      Egghead.search_by_class(:agent)
      |> Enum.map(& &1.id)

    all_ids = Enum.uniq(["egghead" | store_agents])

    all_ids
    |> Enum.filter(fn id -> agent_name(id) |> GenServer.whereis() != nil end)
    |> Enum.map(fn id ->
      name = agent_name(id)
      state = :sys.get_state(GenServer.whereis(name))

      # Aggregate usage across all sessions
      {total_usage, total_session_tokens, total_history} =
        state.sessions
        |> Map.values()
        |> Enum.reduce({%{input_tokens: 0, output_tokens: 0}, 0, 0}, fn pid,
                                                                        {usage, stok, hist} ->
          case safe_get_session_state(pid) do
            nil ->
              {usage, stok, hist}

            session_state ->
              {
                %{
                  input_tokens: usage.input_tokens + session_state.usage.input_tokens,
                  output_tokens: usage.output_tokens + session_state.usage.output_tokens
                },
                stok + session_state.session_tokens,
                hist + length(session_state.history)
              }
          end
        end)

      %{
        id: state.id,
        name: state.name,
        capabilities: state.capabilities,
        model: state.model,
        usage: total_usage,
        session_tokens: total_session_tokens,
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

  # --- GenServer callbacks ---

  @impl true
  def init(record) do
    capabilities = parse_capabilities(record)
    thinking = get_meta_string(record, "thinking", nil)
    max_tokens = get_meta_int(record, "max_tokens", 4096)
    temperature = get_meta_float(record, "temperature", nil)

    context_threshold =
      get_meta_float(record, "context_threshold", @default_context_threshold)

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
      capabilities: capabilities,
      thinking: thinking,
      max_tokens: max_tokens,
      temperature: temperature,
      context_threshold: context_threshold
    }

    Logger.info(
      "Agent started: #{state.name} (#{state.id}) model=#{model} capabilities=#{inspect(capabilities)}"
    )

    send(self(), :fetch_model_info)

    {:ok, state}
  end

  @impl true
  def handle_call({:prompt, message, opts}, _from, state) do
    room = Keyword.get(opts, :room)
    room_id = if room, do: room.id
    room_pid = if room_id, do: room_process(room_id)

    {session_pid, state} = ensure_session(state, room_id, room_pid)
    result = Session.prompt(session_pid, message, opts)
    {:reply, result, state}
  end

  def handle_call({:handoff, opts}, _from, state) when is_list(opts) do
    room_id = Keyword.get(opts, :room_id)
    session_key = room_id || :default

    case Map.get(state.sessions, session_key) do
      nil ->
        {:reply, {:error, :no_history}, state}

      pid ->
        result = Session.handoff(pid, opts)
        {:reply, result, state}
    end
  end

  def handle_call(:save, _from, state) do
    case Map.get(state.sessions, :default) do
      nil -> {:reply, {:error, :no_history}, state}
      pid -> {:reply, Session.save(pid), state}
    end
  end

  def handle_call(:clear_history, _from, state) do
    case Map.get(state.sessions, :default) do
      nil -> {:reply, :ok, state}
      pid -> {:reply, Session.clear_history(pid), state}
    end
  end

  def handle_call(:usage, _from, state) do
    case Map.get(state.sessions, :default) do
      nil ->
        {:reply,
         {:ok,
          %{
            total_usage: %{input_tokens: 0, output_tokens: 0},
            session_tokens: 0,
            context_window: state.context_window,
            context_used_pct: nil,
            history_turns: 0,
            referenced_records: []
          }}, state}

      pid ->
        {:reply, Session.usage(pid), state}
    end
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

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # A session died — clean it from our sessions map
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

  defp build_identity(state) do
    %{
      id: state.id,
      name: state.name,
      disposition: state.disposition,
      model: state.model,
      capabilities: state.capabilities,
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

  defp fallback_context_window(model) do
    cond do
      String.contains?(model, "opus") -> 1_000_000
      String.contains?(model, "haiku") -> 200_000
      true -> 200_000
    end
  end
end
