defmodule Egghead.Web.ChatLive do
  use Egghead.Web, :live_view

  alias Egghead.Chat.Room
  alias Egghead.TUI.Chat.{Entry, Stream}
  alias Egghead.Web.MarkdownHTML

  @impl true
  def mount(_params, _session, socket) do
    room_id = Egghead.default_room()

    socket =
      if room_id do
        if connected?(socket), do: Room.subscribe(room_id)

        transcript = hydrate_transcript(room_id)

        assign(socket,
          room_id: room_id,
          transcript: transcript,
          active_streams: %{},
          status: nil,
          agents: []
        )
      else
        assign(socket,
          room_id: nil,
          transcript: [],
          active_streams: %{},
          status: "Waiting for chat room to start...",
          agents: []
        )
      end

    {:ok, socket}
  end

  # --- user actions ---

  @impl true
  def handle_event("send", %{"message" => message}, socket) do
    message = String.trim(message)

    cond do
      message == "" ->
        {:noreply, socket}

      message == "/continue" && socket.assigns.room_id ->
        Egghead.chat_continue(socket.assigns.room_id)
        {:noreply, socket}

      message == "/save" && socket.assigns.room_id ->
        Egghead.chat_save(socket.assigns.room_id)
        {:noreply, assign(socket, status: "Transcript saved.")}

      socket.assigns.room_id ->
        Egghead.chat(socket.assigns.room_id, message)
        {:noreply, socket}

      true ->
        {:noreply, assign(socket, status: "No chat room available.")}
    end
  end

  # --- room PubSub events ---

  @impl true
  def handle_info({:user_message, msg}, socket) do
    entry = Entry.user(msg.sender.name, msg.content)
    {:noreply, append_entry(socket, entry)}
  end

  def handle_info({:agent_message, msg}, socket) do
    socket =
      socket
      |> finalize_stream(msg.sender.id)
      |> drop_stream(msg.sender.id)

    {:noreply, socket}
  end

  def handle_info({:agent_streaming, _room_id, agent_id, delta}, socket) do
    {:noreply, apply_stream_delta(socket, agent_id, delta)}
  end

  def handle_info({:agent_tool_call, _room_id, agent_id, name, input}, socket) do
    text = format_tool_call(name, input)
    display = agent_display_name(agent_id)
    entry = Entry.action(agent_id, display, text)
    {:noreply, append_entry(socket, entry)}
  end

  def handle_info({:agents_activated, _count}, socket) do
    {:noreply, socket}
  end

  def handle_info({:agent_passed, agent_id}, socket) do
    {:noreply, drop_stream(socket, agent_id)}
  end

  def handle_info(:budget_exhausted, socket) do
    {:noreply, assign(socket, status: "Budget exhausted — type /continue to grant more turns.")}
  end

  def handle_info(:continued, socket) do
    {:noreply, assign(socket, status: nil)}
  end

  def handle_info({:agent_joined, agent_id}, socket) do
    entry = Entry.system("#{agent_display_name(agent_id)} joined")
    {:noreply, append_entry(socket, entry)}
  end

  def handle_info({:agent_left, agent_id}, socket) do
    entry = Entry.system("#{agent_display_name(agent_id)} left")
    {:noreply, append_entry(socket, entry)}
  end

  def handle_info({:agent_handoff, _room_id, agent_id, _delib_id}, socket) do
    entry = Entry.system("#{agent_display_name(agent_id)} handed off context")
    {:noreply, append_entry(socket, entry)}
  end

  def handle_info({:agent_mentions, _room_id, _from, _to}, socket) do
    {:noreply, socket}
  end

  def handle_info({:system_notice, text}, socket) do
    {:noreply, append_entry(socket, Entry.system(text))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # --- stream management ---

  defp apply_stream_delta(socket, agent_id, delta) do
    current = socket.assigns.active_streams
    name = agent_display_name(agent_id)
    s = Map.get(current, agent_id, Stream.new(agent_id, name))
    {s, committed} = Stream.append(s, delta)

    socket
    |> assign(active_streams: Map.put(current, agent_id, s))
    |> append_entries(committed)
  end

  defp finalize_stream(socket, agent_id) do
    case Map.get(socket.assigns.active_streams, agent_id) do
      nil -> socket
      stream -> append_entries(socket, Stream.finalize(stream))
    end
  end

  defp drop_stream(socket, agent_id) do
    assign(socket, active_streams: Map.delete(socket.assigns.active_streams, agent_id))
  end

  defp append_entry(socket, entry) do
    assign(socket, transcript: socket.assigns.transcript ++ [entry])
  end

  defp append_entries(socket, []), do: socket

  defp append_entries(socket, entries) do
    assign(socket, transcript: socket.assigns.transcript ++ entries)
  end

  # --- helpers ---

  defp hydrate_transcript(room_id) do
    case Room.get_transcript(room_id) do
      {:ok, messages} ->
        Enum.map(messages, fn msg ->
          case msg.sender.type do
            :user -> Entry.user(msg.sender.name, msg.content)
            :agent -> Entry.agent(msg.sender.id, msg.sender.name, msg.content)
          end
        end)

      _ ->
        []
    end
  end

  defp agent_display_name(agent_id) do
    agent_id |> String.split("/") |> List.last() |> String.capitalize()
  end

  defp format_tool_call(name, input) do
    args = input |> inspect(pretty: true, limit: 3)
    "#{name}(#{args})"
  end

  defp render_entry_html(%Entry{kind: :agent, text: text}) do
    MarkdownHTML.render(text)
  end

  defp render_entry_html(%Entry{text: text}) do
    Egghead.Web.MarkdownHTML.render(text)
  end

  # --- ghost text (in-progress streaming) ---

  defp ghost_entries(streams) do
    streams
    |> Enum.filter(fn {_id, s} -> Stream.has_text?(s) end)
    |> Enum.map(fn {_id, s} -> {s.name, s.current} end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="chat-layout">
      <div class="chat-transcript" id="chat-transcript" phx-hook="ScrollBottom">
        <div
          :for={entry <- @transcript}
          class={["chat-entry", "entry-#{entry.kind}"]}
        >
          <span :if={entry.sender_name} class="entry-sender">{entry.sender_name}</span>
          <span :if={entry.timestamp} class="entry-time">
            {Calendar.strftime(entry.timestamp, "%H:%M")}
          </span>
          <div class="entry-body">{Phoenix.HTML.raw(render_entry_html(entry))}</div>
        </div>

        <div
          :for={{name, text} <- ghost_entries(@active_streams)}
          class="chat-entry entry-agent ghost"
        >
          <span class="entry-sender">{name}</span>
          <div class="entry-body">{text}</div>
        </div>
      </div>

      <div :if={@status} class="chat-status">{@status}</div>

      <form phx-submit="send" class="chat-input">
        <input
          type="text"
          name="message"
          placeholder={if @room_id, do: "Type a message...", else: "No room available"}
          autocomplete="off"
          disabled={is_nil(@room_id)}
        />
        <button type="submit" disabled={is_nil(@room_id)}>Send</button>
      </form>
    </div>
    """
  end
end
