defmodule Egghead.Application do
  @moduledoc """
  OTP Application for Egghead.

  Supervision tree layout:

      Egghead.Supervisor (rest_for_one)
      ├── Egghead.LLM.Registry — provider configuration and model resolution
      ├── Egghead.Index — SQLite-backed graph index
      ├── Egghead.RecordStore — filesystem watcher, delegates queries to Index
      ├── Egghead.Agent.Supervisor — dynamic supervisor for agent processes
      │
      │   Future children (not yet implemented):
      ├── Egghead.MCP.Server — MCP protocol endpoint (auto-start)
      └── Egghead.TUI — terminal interface process
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
          {Egghead.LLM.Registry, records_dir: records_dir},
          {Egghead.Index, db_path: db_path},
          {Egghead.RecordStore, records_dir: records_dir},
          {Egghead.Agent.Supervisor, []}
        ]
      else
        []
      end

    opts = [strategy: :rest_for_one, name: Egghead.Supervisor]
    result = Supervisor.start_link(children, opts)

    # After the tree is up, sync agents from the record store
    if Application.get_env(:egghead, :start_record_store, true) do
      Task.start(fn -> Egghead.Agent.Supervisor.sync_agents() end)
    end

    result
  end
end
