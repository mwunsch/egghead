defmodule Egghead.Agent.LayerSupervisor do
  @moduledoc """
  Supervisor for the agent layer: LLM Registry, Coordinator, Agent DynamicSupervisor.

  Independent of the record store layer. If this crashes, the record
  store keeps running. When Registry restarts, agents re-sync.
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
      {Egghead.Chat.Coordinator, []},
      {Egghead.Agent.Supervisor, []}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
