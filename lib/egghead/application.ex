defmodule Egghead.Application do
  @moduledoc """
  OTP Application for Egghead.

  Supervision tree:

      Egghead.Supervisor (one_for_one)
      ├── Egghead.PubSub — event broadcasting
      ├── Egghead.RecordSupervisor (rest_for_one)
      │   ├── Egghead.Index — SQLite graph index
      │   └── Egghead.RecordStore — file watcher, queries
      └── Egghead.Agent.LayerSupervisor (rest_for_one)
          ├── Egghead.LLM.Registry — provider config
          └── Egghead.Agent.Supervisor — DynamicSupervisor for agents
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
          {Phoenix.PubSub, name: Egghead.PubSub},
          {Egghead.RecordSupervisor, records_dir: records_dir, db_path: db_path},
          {Egghead.Agent.LayerSupervisor, records_dir: records_dir}
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Egghead.Supervisor]
    result = Supervisor.start_link(children, opts)

    if Application.get_env(:egghead, :start_record_store, true) do
      Task.start(fn ->
        Egghead.Agent.Supervisor.sync_agents()

        # Create the default chat room once agents are synced
        room_id =
          "chat-#{Date.to_iso8601(Date.utc_today())}-#{:erlang.unique_integer([:positive])}"

        Egghead.create_room(id: room_id, default: true)
      end)
    end

    result
  end
end
