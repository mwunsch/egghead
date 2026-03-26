defmodule Egghead.Application do
  @moduledoc """
  OTP Application for Egghead.

  Supervision tree layout:

      Egghead.Supervisor (rest_for_one)
      ├── Egghead.Index — SQLite-backed graph index (starts first)
      ├── Egghead.RecordStore — filesystem watcher, delegates queries to Index
      │
      │   Future children (not yet implemented):
      ├── Egghead.AgentSupervisor — dynamic supervisor for agent processes
      ├── Egghead.MCP.Server — MCP protocol endpoint
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
          {Egghead.Index, db_path: db_path},
          {Egghead.RecordStore, records_dir: records_dir}
        ]
      else
        []
      end

    opts = [strategy: :rest_for_one, name: Egghead.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
