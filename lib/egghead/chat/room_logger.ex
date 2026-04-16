defmodule Egghead.Chat.RoomLogger do
  @moduledoc """
  Subscribes to a chat room and logs events via Logger.

  Used in IEX for watching agent conversations. The same PubSub pattern
  can be used by TUI, Phoenix Channels, and IRC — different renderers,
  same event stream.

  Streaming deltas are line-buffered per agent to prevent interleaving
  when multiple agents respond concurrently.

  ## Usage

      pid = Egghead.watch("lobby")
      send(pid, :stop)  # to stop watching
  """

  require Logger

  @pubsub Egghead.PubSub

  @doc """
  Starts a room logger process.
  """
  @spec start(String.t()) :: pid()
  def start(room_id) do
    spawn(fn ->
      Phoenix.PubSub.subscribe(@pubsub, Egghead.Chat.Room.topic(room_id))
      Logger.info("Watching room: #{room_id}")
      loop(room_id, %{})
    end)
  end

  # buffers: %{agent_id => %{name: "Scout", text: "partial line..."}}
  defp loop(room_id, buffers) do
    receive do
      {:user_message, msg} ->
        buffers = flush_all(buffers)
        Logger.info("#{msg.sender.name}: #{msg.content}")
        loop(room_id, buffers)

      {:agent_streaming, _room_id, agent_id, delta} ->
        buf = Map.get(buffers, agent_id, %{name: display_name(agent_id), text: ""})
        buf = %{buf | text: buf.text <> delta}

        {flushed, remainder} = split_lines(buf.text)

        if flushed != "" do
          log_agent_lines(buf.name, flushed)
        end

        buffers = Map.put(buffers, agent_id, %{buf | text: remainder})
        loop(room_id, buffers)

      {:agent_message, msg} ->
        buffers = flush_agent(buffers, msg.sender.id)
        usage_info = format_usage(msg.usage)

        if Map.has_key?(buffers, msg.sender.id) do
          if usage_info != "", do: Logger.debug(usage_info)
        else
          Logger.info("#{msg.sender.name}#{usage_info}: #{msg.content}")
        end

        buffers = Map.delete(buffers, msg.sender.id)
        loop(room_id, buffers)

      {:agent_tool_call, _room_id, agent_id, tool_name, input} ->
        buffers = flush_agent(buffers, agent_id)
        name = agent_id |> String.split("/") |> List.last()
        summary = format_tool_call(tool_name, input)
        Logger.debug("#{name} → #{tool_name}(#{summary})")
        loop(room_id, buffers)

      {:agent_tool_denied, _room_id, agent_id, tool_name, _input, denial} ->
        buffers = flush_agent(buffers, agent_id)
        name = agent_id |> String.split("/") |> List.last()
        Logger.info("⚠ #{name} denied on #{tool_name}: #{denial.message}")
        loop(room_id, buffers)

      {:agent_joined, agent_id} ->
        Logger.debug("#{agent_id} joined")
        loop(room_id, buffers)

      {:agent_left, agent_id} ->
        Logger.debug("#{agent_id} left")
        loop(room_id, buffers)

      :budget_exhausted ->
        Logger.info("Turn budget exhausted (use Egghead.chat_continue/1)")
        loop(room_id, buffers)

      :continued ->
        Logger.debug("Continued")
        loop(room_id, buffers)

      {:agent_mentions, _room_id, from, mentioned, _content} ->
        Logger.debug("#{from} mentioned #{Enum.join(mentioned, ", ")}")
        loop(room_id, buffers)

      {:agents_activated, count} ->
        Logger.debug("#{count} agents activated")
        loop(room_id, buffers)

      {:agent_passed, agent_id} ->
        Logger.debug("#{agent_id} passed")
        loop(room_id, buffers)

      {:agent_handoff, _room_id, agent_id, delib_id} ->
        Logger.info("#{agent_id} handed off → #{delib_id}")
        loop(room_id, buffers)

      :stop ->
        flush_all(buffers)
        Logger.info("Stopped watching #{room_id}")
        :ok

      _other ->
        loop(room_id, buffers)
    end
  end

  defp split_lines(text) do
    case String.split(text, "\n") do
      [only] -> {"", only}
      parts -> {Enum.slice(parts, 0..-2//1) |> Enum.join("\n"), List.last(parts)}
    end
  end

  defp log_agent_lines(name, text) do
    text
    |> String.split("\n")
    |> Enum.each(fn line ->
      Logger.info("#{name}: #{line}")
    end)
  end

  defp flush_agent(buffers, agent_id) do
    case Map.get(buffers, agent_id) do
      %{name: name, text: text} when text != "" ->
        log_agent_lines(name, text)
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
    case usage[:context_pct] do
      nil -> ""
      pct -> " [ctx:#{pct}%]"
    end
  end
end
