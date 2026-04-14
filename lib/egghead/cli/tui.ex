defmodule Egghead.CLI.TUI do
  @moduledoc "Launches the Egghead TUI."

  def run(args) when is_list(args) do
    if "--help" in args or "-h" in args do
      IO.puts("""
      USAGE
        egghead [tui]

      DESCRIPTION
        Launch the terminal UI. This is the default command when no
        subcommand is given.

      ENVIRONMENT
        EGGHEAD_RECORDS_DIR   Override the records directory

      SEE ALSO
        egghead serve, egghead init
      """)
    else
      do_run()
    end
  end

  defp do_run do
    # First-run detection
    unless Egghead.Config.exists?() do
      Egghead.CLI.Init.run([])
    end

    # Honor EGGHEAD_RECORDS_DIR override
    if records_dir = System.get_env("EGGHEAD_RECORDS_DIR") do
      Application.put_env(:egghead, :records_dir, records_dir)
    end

    Egghead.CLI.start_app(:file, web: false)

    # Let OS signals kill the process cleanly (no zombie on terminal close)
    :os.set_signal(:sighup, :default)
    :os.set_signal(:sigterm, :default)

    # Run the TUI — blocks until exit
    Egghead.tui()

    System.halt(0)
  end
end
