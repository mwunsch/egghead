defmodule Egghead.Chat.ToolCache do
  @moduledoc """
  ETS-based cache for read-only tool results within a room context.

  When multiple agents in the same room search for the same thing or fetch
  the same record, the second call returns the cached result. This avoids
  redundant work and reduces context pressure (identical tool results don't
  need to be stored in each agent's history independently).

  Cache entries expire after 60 seconds. Write operations (create_record,
  update_record) are never cached.

  Note: cache is keyed by {room_id, tool_name, input_hash} without per-agent
  capability scoping. This assumes all agents in a room have equivalent read
  access to records.
  TODO(security): when pledge/unveil capability scopes ship, add capability
  hash to cache key to prevent cross-agent leaks.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @ttl_ms 60_000

  @read_only_tools ~w(search_records get_record get_record_body list_records
                       find_backlinks find_links recent_records)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns a cached result or executes the function and caches the result.
  Only caches successful ({:ok, _}) results for read-only tools.
  Returns nil (cache miss) for non-cacheable tools or when no room_id.
  """
  @spec get_or_execute(String.t() | nil, String.t(), map(), (-> {:ok, String.t()}
                                                                | {:error, String.t()})) ::
          {:ok, String.t()} | {:error, String.t()}
  def get_or_execute(nil, _tool_name, _input, fun), do: fun.()

  def get_or_execute(room_id, tool_name, input, fun) do
    if tool_name in @read_only_tools do
      key = {room_id, tool_name, :erlang.phash2(input)}

      case lookup(key) do
        {:ok, result} ->
          Logger.debug("ToolCache hit: #{tool_name} in #{room_id}")
          {:ok, result}

        :miss ->
          case fun.() do
            {:ok, result} = ok ->
              insert(key, result)
              ok

            error ->
              error
          end
      end
    else
      fun.()
    end
  end

  @doc """
  Invalidate all cache entries for a room.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(room_id) do
    :ets.match_delete(@table, {{room_id, :_, :_}, :_, :_})
    :ok
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end

  # --- Private ---

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, result, inserted_at}] ->
        if System.monotonic_time(:millisecond) - inserted_at < @ttl_ms do
          {:ok, result}
        else
          :ets.delete(@table, key)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp insert(key, result) do
    :ets.insert(@table, {key, result, System.monotonic_time(:millisecond)})
  end
end
