defmodule Egghead.Chat.Watcher do
  @moduledoc """
  Subscribes to a chat room and prints messages to stdout in real time.

  Used in IEX for watching agent conversations. The same PubSub pattern
  is used by TUI, Phoenix Channels, and IRC — different renderers,
  same event stream.

  Streaming deltas are line-buffered per agent to prevent interleaving
  when multiple agents respond concurrently. Each line is prefixed with
  the agent name.

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
      loop(room_id, %{})
    end)
  end

  # buffers: %{agent_id => %{name: "Scout", text: "partial line..."}}
  defp loop(room_id, buffers) do
    receive do
      {:user_message, msg} ->
        buffers = flush_all(buffers)
        IO.puts("")
        IO.puts(IO.ANSI.green() <> "#{msg.sender.name}" <> IO.ANSI.reset() <> ": #{msg.content}")
        loop(room_id, buffers)

      {:agent_streaming, _room_id, agent_id, delta} ->
        buf = Map.get(buffers, agent_id, %{name: display_name(agent_id), text: ""})
        buf = %{buf | text: buf.text <> delta}

        # Flush complete lines (up to last newline)
        {flushed, remainder} = split_lines(buf.text)

        if flushed != "" do
          print_agent_lines(buf.name, flushed)
        end

        buffers = Map.put(buffers, agent_id, %{buf | text: remainder})
        loop(room_id, buffers)

      {:agent_message, msg} ->
        # Flush any remaining buffer for this agent
        buffers = flush_agent(buffers, msg.sender.id)
        usage_info = format_usage(msg.usage)

        if Map.has_key?(buffers, msg.sender.id) do
          # Was streaming — just print usage on its own line
          IO.puts(IO.ANSI.faint() <> "  #{usage_info}" <> IO.ANSI.reset())
        else
          # Not streaming (non-streaming provider) — print full message
          IO.puts("")

          IO.puts(
            IO.ANSI.yellow() <>
              "#{msg.sender.name}" <> IO.ANSI.reset() <> usage_info <> ": #{msg.content}"
          )
        end

        buffers = Map.delete(buffers, msg.sender.id)
        loop(room_id, buffers)

      {:agent_tool_call, _room_id, agent_id, tool_name, input} ->
        # Flush this agent's buffer before showing the tool call
        buffers = flush_agent(buffers, agent_id)
        name = agent_id |> String.split("/") |> List.last()
        summary = format_tool_call(tool_name, input)

        IO.puts(
          IO.ANSI.faint() <>
            "  #{name} → #{tool_name}(#{summary})" <>
            IO.ANSI.reset()
        )

        loop(room_id, buffers)

      {:agent_joined, agent_id} ->
        IO.puts(IO.ANSI.faint() <> "  → #{agent_id} joined" <> IO.ANSI.reset())
        loop(room_id, buffers)

      {:agent_left, agent_id} ->
        IO.puts(IO.ANSI.faint() <> "  ← #{agent_id} left" <> IO.ANSI.reset())
        loop(room_id, buffers)

      :budget_exhausted ->
        IO.puts(
          IO.ANSI.faint() <>
            "  ⏸ turn budget exhausted (use Egghead.chat_continue/1)" <> IO.ANSI.reset()
        )

        loop(room_id, buffers)

      :continued ->
        IO.puts(IO.ANSI.faint() <> "  ▶ continued" <> IO.ANSI.reset())
        loop(room_id, buffers)

      {:agent_mentions, _room_id, from, mentioned} ->
        IO.puts(
          IO.ANSI.faint() <>
            "  #{from} mentioned #{Enum.join(mentioned, ", ")}" <>
            IO.ANSI.reset()
        )

        loop(room_id, buffers)

      {:agents_activated, count} ->
        IO.puts(IO.ANSI.faint() <> "  #{count} agents activated" <> IO.ANSI.reset())
        loop(room_id, buffers)

      {:agent_passed, agent_id} ->
        IO.puts(IO.ANSI.faint() <> "  #{agent_id} passed" <> IO.ANSI.reset())
        loop(room_id, buffers)

      :stop ->
        flush_all(buffers)
        IO.puts(IO.ANSI.faint() <> "Stopped watching #{room_id}" <> IO.ANSI.reset())
        :ok

      _other ->
        loop(room_id, buffers)
    end
  end

  # Split text at the last newline. Returns {complete_lines, remainder}.
  defp split_lines(text) do
    case String.split(text, "\n") do
      [only] -> {"", only}
      parts -> {Enum.slice(parts, 0..-2//1) |> Enum.join("\n"), List.last(parts)}
    end
  end

  defp print_agent_lines(name, text) do
    text
    |> String.split("\n")
    |> Enum.each(fn line ->
      IO.puts(IO.ANSI.yellow() <> name <> IO.ANSI.reset() <> ": " <> line)
    end)
  end

  defp flush_agent(buffers, agent_id) do
    case Map.get(buffers, agent_id) do
      %{name: name, text: text} when text != "" ->
        print_agent_lines(name, text)
        Map.put(buffers, agent_id, %{name: name, text: ""})

      _ ->
        buffers
    end
  end

  defp flush_all(buffers) do
    Enum.reduce(buffers, buffers, fn {agent_id, _}, acc ->
      flush_agent(acc, agent_id)
    end)
  end

  defp display_name(agent_id) do
    agent_id |> String.split("/") |> List.last() |> String.capitalize()
  end

  defp format_tool_call(_, nil), do: ""

  defp format_tool_call(_name, input) when is_map(input) do
    cond do
      input["query"] -> inspect(input["query"])
      input["id"] -> inspect(input["id"])
      input["title"] -> inspect(input["title"])
      true -> ""
    end
  end

  defp format_tool_call(_, _), do: ""

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
