defmodule Egghead.Application do
  @moduledoc """
  OTP Application for Egghead.

  Supervision tree layout:

      Egghead.Supervisor (one_for_one)
      ├── Egghead.RecordSupervisor (rest_for_one)
      │   ├── Egghead.Index — SQLite graph index
      │   └── Egghead.RecordStore — file watcher, queries
      └── Egghead.Agent.LayerSupervisor (rest_for_one)
          ├── Egghead.LLM.Registry — provider config, model resolution
          └── Egghead.Agent.Supervisor — DynamicSupervisor for agents

  The record store is independent of the LLM/agent layer. If the
  Registry crashes, agents restart but the record store keeps running.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:egghead, :start_record_store, true) do
        records_dir =
          Application.get_env(:egghead, :records_dir, Path.join(File.cwd!(), "records"))

        db_path = Path.join(records_dir, ".egghead/index.db")

        [
          {Egghead.RecordSupervisor, records_dir: records_dir, db_path: db_path},
          {Egghead.Agent.LayerSupervisor, records_dir: records_dir}
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Egghead.Supervisor]
    result = Supervisor.start_link(children, opts)

    # After the tree is up, sync agents from the record store
    if Application.get_env(:egghead, :start_record_store, true) do
      Task.start(fn -> Egghead.Agent.Supervisor.sync_agents() end)
    end

    result
  end
end
