defmodule Egghead.CLI.Logs do
  @moduledoc "Tail the application log file."

  def run(args) do
    if "--help" in args or "-h" in args do
      IO.puts("""
      USAGE
        egghead logs [flags]

      DESCRIPTION
        Tail the Egghead log file. Logs are written to
        ~/.local/state/egghead/egghead.log (respects $XDG_STATE_HOME).
        Run this in a separate terminal to watch logs while using the TUI.

      FLAGS
        -n, --lines <n>   Number of lines to show initially (default: 10)
        -h, --help        Show this help

      EXAMPLES
        $ egghead logs
        $ egghead logs -n 50

      SEE ALSO
        egghead doctor
      """)
    else
      do_run(args)
    end
  end

  defp do_run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [lines: :integer],
        aliases: [n: :lines]
      )

    log_file = Egghead.Config.log_path()
    lines = opts[:lines] || 10

    if File.exists?(log_file) do
      System.cmd("tail", ["-n", to_string(lines), "-f", log_file], into: IO.stream(:stdio, :line))
    else
      IO.puts("Log file not found: #{log_file}")
      IO.puts("Start the TUI or run a command first — logging creates this file.")
    end
  end
end
