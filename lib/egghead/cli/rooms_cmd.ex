defmodule Egghead.CLI.RoomsCmd do
  @moduledoc false

  alias Egghead.CLI.Widgets

  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        switches: [help: :boolean, no_save: :boolean],
        aliases: [h: :help]
      )

    if opts[:help] do
      print_help()
    else
      case positional do
        [] -> do_list()
        ["list" | _] -> do_list()
        ["new" | rest] -> do_new(rest)
        ["drop" | rest] -> do_drop(rest, opts)
        ["show", id | _] -> do_show(id)
        ["show" | _] -> IO.puts("Usage: egghead rooms show <room-id>")
        [other | _] -> IO.puts("Unknown subcommand: #{other}\nRun `egghead rooms --help`.")
      end
    end
  end

  defp do_list do
    Egghead.CLI.prepare_runtime()

    rooms = Egghead.list_rooms()

    if rooms == [] do
      IO.puts("No open rooms.")
    else
      default = Egghead.default_room()

      Widgets.header("Rooms")

      Enum.each(rooms, fn room_id ->
        marker = if room_id == default, do: " \e[33m(default)\e[0m", else: ""

        info =
          try do
            state = Egghead.Chat.Room.get_state(room_id)
            agents = length(state.agents || [])
            msgs = state.message_count || 0
            "  \e[90m#{agents} agents, #{msgs} messages\e[0m"
          catch
            _, _ -> ""
          end

        IO.puts("  #{room_id}#{marker}#{info}")
      end)

      IO.puts("")
      IO.puts("  #{length(rooms)} room(s)")
    end
  end

  defp do_new(rest) do
    Egghead.CLI.prepare_runtime()

    name = List.first(rest)

    case Egghead.create_room(if(name, do: [id: name], else: [])) do
      {:ok, room_id} ->
        IO.puts("Created room: #{room_id}")

      {:error, reason} ->
        IO.puts("Failed to create room: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp do_drop(rest, opts) do
    Egghead.CLI.prepare_runtime()

    case rest do
      [room_id | _] ->
        case Egghead.stop_room(room_id, no_save: opts[:no_save] || false) do
          :ok ->
            if opts[:no_save] do
              IO.puts("Dropped room: #{room_id}")
            else
              IO.puts("Saved transcript and dropped room: #{room_id}")
            end

          {:error, :is_default_room} ->
            IO.puts("Cannot drop the default room.")
            System.halt(1)
        end

      [] ->
        IO.puts("Usage: egghead rooms drop <room-id> [--no-save]")
        System.halt(1)
    end
  end

  defp do_show(room_id) do
    Egghead.CLI.prepare_runtime()

    unless Egghead.room_exists?(room_id) do
      IO.puts("Room not found: #{room_id}")
      System.halt(1)
    end

    state = Egghead.Chat.Room.get_state(room_id)
    default = Egghead.default_room()

    Widgets.header("Room: #{room_id}")
    if room_id == default, do: IO.puts("  default: yes")
    IO.puts("  mode:     #{state.mode || :serial}")
    IO.puts("  status:   #{state.status || :waiting}")
    IO.puts("  messages: #{state.message_count || 0}")
    IO.puts("  budget:   #{state.rounds_remaining || 0}/#{state.round_budget || 0}")

    agents = state.agents || []
    IO.puts("  agents:   #{length(agents)}")

    if agents != [] do
      Enum.each(agents, fn id ->
        IO.puts("    - #{id}")
      end)
    end
  end

  defp print_help do
    IO.puts("""
    USAGE
      egghead rooms [command] [flags]

    COMMANDS
      list                List open rooms (default)
      new [name]          Create a new room (auto-names if omitted)
      drop <id>           Drop a room (saves transcript first)
      show <id>           Show room details

    FLAGS
      --no-save           Skip transcript save when dropping

    EXAMPLES
      $ egghead rooms
      $ egghead rooms new design-review
      $ egghead rooms show design-review
      $ egghead rooms drop design-review
      $ egghead rooms drop old-room --no-save

    SEE ALSO
      egghead serve
    """)
  end
end
