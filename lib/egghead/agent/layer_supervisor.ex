defmodule Egghead.Agent.LayerSupervisor do
  @moduledoc """
  Supervisor for the agent layer: LLM Registry, Coordinator, Agent DynamicSupervisor.

  Independent of the record store layer. If this crashes, the record
  store keeps running.

  ## Strategy: `one_for_one`

  Each child is independently restartable. A Coordinator crash does
  NOT take agents down, because:

    * Agents look up the Coordinator by registered name, not cached
      pid — a new Coordinator answers to the same name.
    * The Coordinator rehydrates its state (agent registry + room
      subscriptions) from the live system on `init/1`, so a restart
      picks up where the previous instance left off.

  LLM.Registry crashes also don't cascade — agents read model config
  through the registry lazily, so a restarted registry is transparent.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    records_dir = Keyword.get(opts, :records_dir)

    children = [
      {Egghead.LLM.Registry, records_dir: records_dir},
      {Egghead.Chat.ToolCache, []},
      {Egghead.Chat.Coordinator, []},
      {Egghead.Agent.Supervisor, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
