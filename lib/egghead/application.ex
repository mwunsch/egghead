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

  ## Log modes

  Set `:log_mode` in application env before `app.start`:

  - `:console` (default) — logs to stdout (for `iex`, `egghead serve`)
  - `:file` — redirects to `Egghead.Config.log_path()` (for TUI)
  - `:silent` — redirects to file, no console output (for CLI commands)
  """

  use Application

  @impl true
  def start(_type, _args) do
    configure_logging()

    children =
      if Application.get_env(:egghead, :start_record_store, true) do
        records_dir =
          Application.get_env(:egghead, :records_dir, Path.join(File.cwd!(), "records"))

        db_path = Path.join(records_dir, ".egghead/index.db")

        [
          {Phoenix.PubSub, name: Egghead.PubSub},
          {Egghead.RecordSupervisor, records_dir: records_dir, db_path: db_path},
          {Egghead.Agent.LayerSupervisor, records_dir: records_dir}
        ] ++ web_children()
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

  defp web_children do
    if Application.get_env(:egghead, :start_web, true) do
      [Egghead.Web.Endpoint]
    else
      []
    end
  end

  defp configure_logging do
    case Application.get_env(:egghead, :log_mode, :console) do
      :file ->
        redirect_to_file()

      :silent ->
        redirect_to_file()

      :console ->
        :ok
    end
  end

  defp redirect_to_file do
    log_path = Egghead.Config.log_path()
    log_dir = Path.dirname(log_path)
    File.mkdir_p!(log_dir)

    for id <- :logger.get_handler_ids() do
      :logger.remove_handler(id)
    end

    :logger.add_handler(:egghead_file, :logger_std_h, %{
      config: %{file: String.to_charlist(log_path)}
    })
  end
end
