defmodule Mix.Tasks.Egghead.Tui do
  @moduledoc """
  Launches the Egghead TUI.

  For proper Ctrl+C handling, use the wrapper script instead:

      ./bin/egghead

  Direct mix usage (Ctrl+C shows BEAM break menu):

      mix egghead.tui

  Logs go to /tmp/egghead.log.
  """

  use Mix.Task

  @shortdoc "Launch the Egghead terminal UI"

  @log_file "/tmp/egghead.log"

  @impl true
  def run(_args) do
    # Start the app FIRST — let it configure Logger however it wants
    Mix.Task.run("app.start")

    # Remove all console handlers and redirect to file.
    for id <- :logger.get_handler_ids() do
      :logger.remove_handler(id)
    end

    :logger.add_handler(:egghead_file, :logger_std_h, %{
      config: %{file: String.to_charlist(@log_file)}
    })

    # Let OS signals kill the process cleanly (no zombie on terminal close)
    :os.set_signal(:sighup, :default)
    :os.set_signal(:sigterm, :default)

    # Run the TUI — blocks until exit
    Egghead.tui()

    # Force all processes to exit — prevents zombie BEAM processes
    System.halt(0)
  end
end
