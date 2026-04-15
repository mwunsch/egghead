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
  Returns the default built-in agent record.

  Used as a fallback when no `class: agent` record with id `"index"`
  exists in the store. Users who want to widen Index's capabilities or
  edit its disposition drop an `index.md` file anywhere in their record
  store with `class: agent` in frontmatter (path is convention, not
  requirement — any agent-class record whose derived id is `"index"`
  will shadow).
  """
  def default_agent do
    # Read the configured default model, fall back to haiku if not set
    {model, provider} =
      case Egghead.Config.load() do
        {:ok, %{default_model: dm}} when is_binary(dm) ->
          case String.split(dm, "/", parts: 2) do
            [p, m] -> {m, p}
            _ -> {dm, nil}
          end

        _ ->
          {"claude-haiku-4-5", "anthropic"}
      end

    %Egghead.Record{
      id: "index",
      title: "Index",
      class: :agent,
      tags: ["agent", "meta", "graph", "backlinks", "store-ops"],
      meta:
        %{
          "model" => model,
          "capabilities" => ["records.read", "records.create"]
        }
        |> then(fn m -> if provider, do: Map.put(m, "provider", provider), else: m end),
      body: """
      You are Index, the record store agent. Your domain is the store itself:
      searching records, navigating the link graph, answering questions about
      what's in the store, and creating records to capture knowledge.

      You handle meta-questions about the system — what agents exist, what
      records link to what, what was recently changed, graph structure and
      backlinks.

      In rooms with other agents: other agents also search records as part of
      their work. Your value is not searching — it's knowing the shape of the
      store. If another agent already searched and listed relevant records,
      do not re-list them. Only respond if you found records they missed or
      can answer a structural question they didn't address (e.g., "what links
      to X", "what changed this week", "how many records have tag Y").

      If a question is outside your domain or already answered, respond with
      [PASS].
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

    # Index override: if any `class: agent` record with id `"index"`
    # exists in the store, it shadows the built-in default. (The class
    # filter is implicit — `agent_records` is already class-filtered
    # above.) Otherwise the built-in runs as fallback so there's always
    # at least one agent available.
    default = default_agent()
    default_name = Egghead.Agent.agent_name(default.id)
    user_provided_index? = Enum.any?(agent_records, &(&1.id == default.id))

    if not user_provided_index? and GenServer.whereis(default_name) == nil do
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
