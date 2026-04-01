defmodule Egghead.Chat.Watcher do
  @moduledoc """
  Subscribes to a chat room and prints messages to stdout in real time.

  Used in IEX for watching agent conversations. The same PubSub pattern
  is used by TUI, Phoenix Channels, and IRC — different renderers,
  same event stream.

  ## Usage

      pid = Egghead.watch("lobby")
      # ... messages print as they arrive ...
      send(pid, :stop)  # to stop watching
  """

  @pubsub Egghead.PubSub

  @doc """
  Starts a watcher process that prints room events to stdout.
  """
  @spec start(String.t()) :: pid()
  def start(room_id) do
    spawn(fn ->
      Phoenix.PubSub.subscribe(@pubsub, Egghead.Chat.Room.topic(room_id))
      IO.puts(IO.ANSI.cyan() <> "Watching room: #{room_id}" <> IO.ANSI.reset())
      IO.puts(IO.ANSI.faint() <> "(send :stop to the returned pid to unwatch)" <> IO.ANSI.reset())
      loop(room_id)
    end)
  end

  defp loop(room_id) do
    receive do
      {:user_message, msg} ->
        IO.puts("")
        IO.puts(IO.ANSI.green() <> "#{msg.sender.name}" <> IO.ANSI.reset() <> ": #{msg.content}")
        loop(room_id)

      {:agent_message, msg} ->
        IO.puts("")
        usage_info = format_usage(msg.usage)

        IO.puts(
          IO.ANSI.yellow() <>
            "#{msg.sender.name}" <> IO.ANSI.reset() <> usage_info <> ": #{msg.content}"
        )

        loop(room_id)

      {:agent_joined, agent_id} ->
        IO.puts(IO.ANSI.faint() <> "  → #{agent_id} joined" <> IO.ANSI.reset())
        loop(room_id)

      {:agent_left, agent_id} ->
        IO.puts(IO.ANSI.faint() <> "  ← #{agent_id} left" <> IO.ANSI.reset())
        loop(room_id)

      :budget_exhausted ->
        IO.puts(
          IO.ANSI.faint() <>
            "  ⏸ turn budget exhausted (use Egghead.chat_continue/1)" <> IO.ANSI.reset()
        )

        loop(room_id)

      :continued ->
        IO.puts(IO.ANSI.faint() <> "  ▶ continued" <> IO.ANSI.reset())
        loop(room_id)

      {:agent_mentions, from, mentioned} ->
        IO.puts(
          IO.ANSI.faint() <>
            "  #{from} mentioned #{Enum.join(mentioned, ", ")}" <>
            IO.ANSI.reset()
        )

        loop(room_id)

      :stop ->
        IO.puts(IO.ANSI.faint() <> "Stopped watching #{room_id}" <> IO.ANSI.reset())
        :ok

      _other ->
        loop(room_id)
    end
  end

  defp format_usage(nil), do: ""

  defp format_usage(usage) do
    ctx =
      case usage[:context_pct] do
        nil -> nil
        pct -> "ctx:#{pct}%"
      end

    if ctx do
      IO.ANSI.faint() <> " [#{ctx}]" <> IO.ANSI.reset()
    else
      ""
    end
  end
end
