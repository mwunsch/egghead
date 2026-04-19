defmodule Egghead.Doc.Supervisor do
  @moduledoc """
  DynamicSupervisor for per-record `Egghead.Doc.Server` processes.
  One server is started per actively-edited record and persists
  for the lifetime of collaborative editing in the web UI.
  """
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
