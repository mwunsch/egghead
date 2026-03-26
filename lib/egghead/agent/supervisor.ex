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
  Returns the default built-in agent record. Always available even when
  no agent records exist in the store.
  """
  def default_agent do
    %Egghead.Record{
      id: "egghead",
      title: "Egghead",
      class: :agent,
      tags: ["agent"],
      meta: %{
        "model" => "claude-sonnet-4-6",
        "provider" => "anthropic",
        "capabilities" => ["record_read", "record_append", "search"]
      },
      body: """
      You are Egghead, the default agent for this record store. You are helpful,
      direct, and knowledgeable about the contents of the store.

      When asked a question, search the records for relevant information and
      provide a well-sourced answer. When asked to explore a topic, search
      broadly and create records for significant findings.

      If the store is empty or doesn't contain relevant information, say so
      honestly and suggest what kinds of records might be worth creating.
      """,
      source_path: nil
    }
  end

  @doc """
  Scans the record store for agent records and starts agent processes
  for any that aren't already running.

  ## Options

    * `:store` — the RecordStore server to query (default: `Egghead.RecordStore`)
  """
  @spec sync_agents(GenServer.server(), keyword()) :: :ok
  def sync_agents(supervisor \\ __MODULE__, opts \\ []) do
    store = Keyword.get(opts, :store, Egghead.RecordStore)
    agent_records = Egghead.RecordStore.search_by_class(store, :agent)

    # Always ensure the default agent is running
    default = default_agent()
    default_name = Egghead.Agent.agent_name(default.id)

    if GenServer.whereis(default_name) == nil do
      start_agent(supervisor, default, store: store)
    end

    # Start agents that aren't running
    Enum.each(agent_records, fn record ->
      name = Egghead.Agent.agent_name(record.id)

      if GenServer.whereis(name) == nil do
        start_agent(supervisor, record, store: store)
      end
    end)

    # Stop agents whose records no longer exist
    running_ids =
      agent_records
      |> Enum.map(& &1.id)
      |> MapSet.new()

    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      if is_pid(pid) do
        case :sys.get_state(pid) do
          %{id: id} ->
            unless MapSet.member?(running_ids, id) or id == default.id do
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
