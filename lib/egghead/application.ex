defmodule Egghead.Application do
  @moduledoc """
  OTP Application for Egghead.

  Supervision tree layout:

      Egghead.Supervisor (one_for_one)
      ├── Egghead.RecordStore — filesystem-backed record index
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

        [{Egghead.RecordStore, records_dir: records_dir}]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Egghead.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
