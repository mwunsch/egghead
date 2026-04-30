defmodule Egghead.Agent.Supervisor do
  @moduledoc """
  Dynamic supervisor for agent processes.

  On start, scans the record store for records with `class: agent` and
  spawns an `Egghead.Agent` process for each. Watches for changes to
  agent records and spawns/restarts/terminates agents accordingly.
  """

  use DynamicSupervisor

  require Logger

  @doc """
  Starts the agent supervisor.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Returns the built-in `index` agent record. Users shadow this by
  writing a `class: agent` record with `id: index` in their store.

  Convenience wrapper around `Egghead.Agent.Builtin.fetch/1` for
  callers (and tests) that still reach for the old name.
  """
  def default_agent do
    Egghead.Agent.Builtin.fetch("index")
  end

  @doc """
  Scans the record store for agent records and starts agent processes
  for any that aren't already running.

  ## Options

    * `:store` — the RecordStore server to query (default: `Egghead.RecordStore`)
  """
  @spec sync_agents(GenServer.server(), keyword()) :: :ok
  def sync_agents(supervisor \\ __MODULE__, opts \\ []) do
    case Egghead.Node.server_node() do
      nil -> sync_agents_local(supervisor, opts)
      node -> :rpc.call(node, __MODULE__, :sync_agents_local, [supervisor, opts])
    end
  end

  @doc false
  def sync_agents_local(supervisor \\ __MODULE__, opts \\ []) do
    store = Keyword.get(opts, :store, Egghead.RecordStore)
    agent_records = Egghead.RecordStore.search_by_class(store, :agent)

    # Built-in agents (Index, Judge, …) live as records in
    # `priv/agents/` and are spawned synthetically when no user record
    # with the same id shadows them. The store-backed copy always wins.
    builtins = Egghead.Agent.Builtin.all()

    Enum.each(builtins, fn default ->
      default_name = Egghead.Agent.agent_name(default.id)
      user_shadow? = Enum.any?(agent_records, &(&1.id == default.id))

      if not user_shadow? and GenServer.whereis(default_name) == nil do
        start_agent(supervisor, default, store: store)
      end
    end)

    # Start agents that aren't running
    Enum.each(agent_records, fn record ->
      name = Egghead.Agent.agent_name(record.id)

      if GenServer.whereis(name) == nil do
        start_agent(supervisor, record, store: store)
      end
    end)

    # Stop agents whose records no longer exist. Synthetic built-ins
    # (Index, Judge, …) are preserved — they have no backing record.
    running_ids =
      agent_records
      |> Enum.map(& &1.id)
      |> MapSet.new()

    synthetic_ids = builtins |> Enum.map(& &1.id) |> MapSet.new()

    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      if is_pid(pid) do
        case :sys.get_state(pid) do
          %{id: id} ->
            unless MapSet.member?(running_ids, id) or MapSet.member?(synthetic_ids, id) do
              Logger.info("Stopping agent: #{id} (record removed)")
              DynamicSupervisor.terminate_child(supervisor, pid)
            end

          _ ->
            :ok
        end
      end
    end)

    :ok
  end

  @doc """
  Starts or restarts an agent from a record.
  """
  @spec start_agent(GenServer.server(), Egghead.Record.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_agent(supervisor \\ __MODULE__, record, opts \\ []) do
    case Egghead.Node.server_node() do
      nil -> start_agent_local(supervisor, record, opts)
      node -> :rpc.call(node, __MODULE__, :start_agent_local, [supervisor, record, opts])
    end
  end

  @doc false
  def start_agent_local(supervisor \\ __MODULE__, record, opts \\ []) do
    store = Keyword.get(opts, :store, Egghead.RecordStore)

    # If already running, restart it
    name = Egghead.Agent.agent_name(record.id)

    case GenServer.whereis(name) do
      nil ->
        :ok

      pid ->
        Logger.info("Restarting agent: #{record.id}")
        DynamicSupervisor.terminate_child(supervisor, pid)
    end

    # Need to hydrate the record to get the full body (disposition)
    record =
      case record.body do
        nil ->
          case Egghead.RecordStore.get_record(store, record.id) do
            {:ok, full} -> full
            {:error, _} -> record
          end

        _ ->
          record
      end

    case DynamicSupervisor.start_child(supervisor, {Egghead.Agent, record}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.warning("Failed to start agent #{record.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Stops an agent by its record id.
  """
  @spec stop_agent(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def stop_agent(supervisor \\ __MODULE__, agent_id) do
    case Egghead.Node.server_node() do
      nil -> stop_agent_local(supervisor, agent_id)
      node -> :rpc.call(node, __MODULE__, :stop_agent_local, [supervisor, agent_id])
    end
  end

  @doc false
  def stop_agent_local(supervisor \\ __MODULE__, agent_id) do
    name = Egghead.Agent.agent_name(agent_id)

    case GenServer.whereis(name) do
      nil ->
        {:error, :not_found}

      pid ->
        DynamicSupervisor.terminate_child(supervisor, pid)
        :ok
    end
  end
end
