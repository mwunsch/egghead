defmodule Egghead.Doc.Supervisor do
  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_server(record_id) do
    spec = {Egghead.Doc.Server, record_id: record_id}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
