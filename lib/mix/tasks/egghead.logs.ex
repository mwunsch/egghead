defmodule Mix.Tasks.Egghead.Logs do
  @moduledoc """
  Tail the Egghead log file.

  Logs are written to `~/.local/state/egghead/egghead.log`
  (respects `$XDG_STATE_HOME`).

      mix egghead.logs
      mix egghead.logs --lines 50
  """

  use Mix.Task

  @shortdoc "Tail application logs"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [help: :boolean, lines: :integer],
        aliases: [h: :help, n: :lines]
      )

    if opts[:help] do
      IO.puts("Usage: egghead logs [-n LINES] [--help]")
    else
      log_file = Egghead.Config.log_path()
      lines = opts[:lines] || 10

      if File.exists?(log_file) do
        System.cmd("tail", ["-n", to_string(lines), "-f", log_file],
          into: IO.stream(:stdio, :line)
        )
      else
        IO.puts("Log file not found: #{log_file}")
        IO.puts("Start the TUI or run a command first — logging creates this file.")
      end
    end
  end
end
