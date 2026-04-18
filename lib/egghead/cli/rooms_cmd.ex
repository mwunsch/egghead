defmodule Egghead.CLI.RoomsCmd do
  @moduledoc """
  `egghead rooms` — list open chat rooms.

  Only meaningful when connected to a running server. A standalone
  process creates a single ephemeral room that disappears when it exits,
  so there's nothing useful to list.
  """

  alias Egghead.CLI.Widgets

  def run(args) do
    if "--help" in args or "-h" in args do
      print_help()
    else
      do_list()
    end
  end

  defp do_list do
    Egghead.CLI.prepare_runtime()

    unless Egghead.Node.connected?() do
      IO.puts("No server running. Start one with `egghead serve` or `egghead`.")
      IO.puts("(Standalone rooms are ephemeral — nothing to list.)")
      System.halt(0)
    end

    rooms = Egghead.list_rooms()

    if rooms == [] do
      IO.puts("No open rooms.")
    else
      default = Egghead.default_room()

      Widgets.header("Rooms")

      Enum.each(rooms, fn room_id ->
        marker = if room_id == default, do: " \e[33m(default)\e[0m", else: ""
        IO.puts("  #{room_id}#{marker}")
      end)

      IO.puts("")
      IO.puts("  #{length(rooms)} room(s)")
      IO.puts("")
      IO.puts("  Join from the TUI with /join <room-id>")
    end
  end

  defp print_help do
    IO.puts("""
    USAGE
      egghead rooms

    DESCRIPTION
      List open chat rooms on the running server. Requires a server
      to be running (via `egghead serve` or another egghead process).

      Standalone rooms are ephemeral and disappear when the process
      exits, so this command only shows rooms on a live server.

    EXAMPLES
      $ egghead rooms

    SEE ALSO
      egghead serve
    """)
  end
end
