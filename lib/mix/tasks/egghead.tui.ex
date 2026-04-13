defmodule Mix.Tasks.Egghead.Tui do
  @moduledoc """
  Launches the Egghead TUI.

  For proper Ctrl+C handling, use the wrapper script instead:

      ./bin/egghead

  Direct mix usage (Ctrl+C shows BEAM break menu):

      mix egghead.tui

  Logs go to ~/.local/state/egghead/egghead.log (see `egghead logs`).
  """

  use Mix.Task

  @shortdoc "Launch the Egghead terminal UI"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, switches: [config: :string])

    if opts[:config], do: System.put_env("EGGHEAD_CONFIG", Path.expand(opts[:config]))

    # First-run detection — if no config exists, run the setup wizard
    unless Egghead.Config.exists?() do
      Mix.Tasks.Egghead.Init.run([])
    end

    # TUI doesn't need the web server — use `egghead serve` for that
    Application.put_env(:egghead, :start_web, false)
    # Redirect logs to file — console output would corrupt the alt screen
    Application.put_env(:egghead, :log_mode, :file)

    # Honor EGGHEAD_RECORDS_DIR override before app.start so the
    # RecordSupervisor picks up the override on boot.
    if records_dir = System.get_env("EGGHEAD_RECORDS_DIR") do
      Application.put_env(:egghead, :records_dir, records_dir)
    end

    Mix.Task.run("app.start")

    # Let OS signals kill the process cleanly (no zombie on terminal close)
    :os.set_signal(:sighup, :default)
    :os.set_signal(:sigterm, :default)

    # Run the TUI — blocks until exit
    Egghead.tui()

    # Force all processes to exit — prevents zombie BEAM processes
    System.halt(0)
  end
end
