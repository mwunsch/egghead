defmodule Egghead.Web.AppLive do
  @moduledoc """
  Main LiveView — the browser counterpart to the TUI. Renders the
  record browser, markdown preview, and chat room alongside each
  other, subscribes to PubSub for record and room events, and
  routes slash commands through the same handlers the TUI uses.
  """
  use Egghead.Web, :live_view

  import Egghead.Web.Components.Window
  alias Egghead.Web.MarkdownHTML
  alias Egghead.Web.OrgHTML
  alias Egghead.TUI.Records.Slug

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Egghead.PubSub, Egghead.RecordStore.records_topic())
      # Push chat completion corpus once we're handling messages.
      send(self(), :push_chat_corpus)
    end

    all = Egghead.list_records() |> Enum.sort_by(&(&1.updated || ""), :desc)

    # Notational Velocity behavior: a record is always selected.
    # When the URL has no id, fall through to the most-recently-updated.
    selected_id =
      case params["id"] do
        nil ->
          case all do
            [%{id: id} | _] -> id
            _ -> nil
          end

        segments when is_list(segments) ->
          Enum.join(segments, "/")

        id when is_binary(id) ->
          id
      end

    # Active room comes from `/chat/:room_id` if present, otherwise
    # the default room. In tests / record-only mode, default_room may
    # be nil — fall back to a sentinel so the render layer never tries
    # `<>` on nil.
    default_room = Egghead.default_room() || "default"
    active_room = params["room_id"] || default_room

    socket =
      socket
      |> assign(
        # Nav state
        query: "",
        all: all,
        filtered: all,
        class_filter: MapSet.new([:durable, :inbox, :deliberation, :transcript, :agent]),
        class_dropdown_open: false,
        view_dropdown_open: false,
        date_format: :relative,
        nav_view: :search,
        tree_open: MapSet.new(),
        # Record state
        selected_id: selected_id,
        selected_record: nil,
        selected_body_html: nil,
        backlinks: [],
        word_count: 0,
        # Chat state — only the active room is subscribed and has full
        # transcript/stream state. The Rooms ▾ dropdown lists every
        # room in the system (Egghead.list_rooms) so there's no
        # separate "open tabs" list to manage.
        active_chat_room: active_room,
        room_id: active_room,
        transcript: [],
        active_streams: %{},
        chat_status: nil,
        chat_input: "",
        rooms_menu_open: false,
        paste_chips: [],
        active_paste_chip: nil,
        agents: [],
        show_agents: false,
        anim_frame: 0
      )
      |> apply_filter()
      |> hydrate_selection()
      |> hydrate_chat()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # When the URL has no id, fall through to the most-recently-updated.
    # The chat route also routes here (no `:id`); we keep whichever record
    # was already selected so navigating to /chat/:room doesn't blank the
    # record window.
    id =
      case params["id"] do
        nil ->
          socket.assigns[:selected_id] ||
            case socket.assigns[:all] do
              [%{id: id} | _] -> id
              _ -> nil
            end

        segments when is_list(segments) ->
          Enum.join(segments, "/")

        id when is_binary(id) ->
          id
      end

    socket =
      if id do
        socket |> assign(selected_id: id) |> hydrate_selection()
      else
        socket
      end

    socket =
      case params["room_id"] do
        nil ->
          socket

        room_id when room_id == socket.assigns.active_chat_room ->
          socket

        new_room_id ->
          socket
          |> unsubscribe_room(socket.assigns.active_chat_room)
          |> assign(
            active_chat_room: new_room_id,
            room_id: new_room_id,
            transcript: [],
            active_streams: %{},
            chat_status: nil,
            chat_input: "",
            paste_chips: [],
            active_paste_chip: nil
          )
          |> hydrate_chat()
      end

    {:noreply, socket}
  end

  defp unsubscribe_room(socket, nil), do: socket

  defp unsubscribe_room(socket, room_id) do
    if connected?(socket) do
      Phoenix.PubSub.unsubscribe(Egghead.PubSub, Egghead.Chat.Room.topic(room_id))
    end

    socket
  end

  # --- UI events ---

  # Window open/close is purely client-side (WindowManager + localStorage).
  # No `toggle_nav` / `toggle_chat` server events — toolbar buttons fire
  # `data-window-toggle` events handled in JS.

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, socket |> assign(query: query) |> apply_filter()}
  end

  def handle_event("select_record", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: "/records/#{id}")}
  end

  def handle_event("toggle_class_dropdown", _, socket) do
    {:noreply, assign(socket, class_dropdown_open: !socket.assigns.class_dropdown_open)}
  end

  def handle_event("toggle_class", %{"class" => class}, socket) do
    class_atom = String.to_existing_atom(class)
    current = socket.assigns.class_filter

    updated =
      if MapSet.member?(current, class_atom),
        do: MapSet.delete(current, class_atom),
        else: MapSet.put(current, class_atom)

    {:noreply, socket |> assign(class_filter: updated) |> apply_filter()}
  end

  def handle_event("class_select_all", _, socket) do
    {:noreply,
     socket
     |> assign(class_filter: MapSet.new([:durable, :inbox, :deliberation, :transcript, :agent]))
     |> apply_filter()}
  end

  def handle_event("class_select_none", _, socket) do
    {:noreply, socket |> assign(class_filter: MapSet.new()) |> apply_filter()}
  end

  def handle_event("switch_nav_view", %{"view" => view}, socket) do
    {:noreply,
     assign(socket,
       nav_view: String.to_existing_atom(view),
       view_dropdown_open: false
     )}
  end

  def handle_event("toggle_view_dropdown", _, socket) do
    {:noreply, assign(socket, view_dropdown_open: !socket.assigns.view_dropdown_open)}
  end

  def handle_event("toggle_date_format", _, socket) do
    next = if socket.assigns.date_format == :relative, do: :iso, else: :relative
    {:noreply, assign(socket, date_format: next)}
  end

  def handle_event("toggle_folder", %{"dir" => dir}, socket) do
    open = socket.assigns.tree_open

    updated =
      if MapSet.member?(open, dir),
        do: MapSet.delete(open, dir),
        else: MapSet.put(open, dir)

    {:noreply, assign(socket, tree_open: updated)}
  end

  def handle_event("create_record", %{"title" => title}, socket) do
    slug = Slug.slugify(title)

    if slug != "" do
      case Egghead.create_record(%{id: slug, class: :durable, title: title}) do
        {:ok, _record} ->
          {:noreply, push_patch(socket, to: "/records/#{slug}")}

        {:error, _reason} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("send_chat", %{"message" => message}, socket) do
    # Reassemble: typed text first, then each pasted chip's full content
    # in the order the user pasted them. The chip is the source of
    # truth for the paste — there's no placeholder string to substitute.
    chips = socket.assigns.paste_chips
    typed = String.trim_trailing(message)

    full_message =
      [typed | Enum.map(chips, & &1.full_text)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
      |> String.trim()

    socket = assign(socket, chat_input: "", paste_chips: [], active_paste_chip: nil)

    cond do
      full_message == "" ->
        {:noreply, socket}

      String.starts_with?(full_message, "/") ->
        {:noreply, dispatch_slash_command(full_message, socket)}

      socket.assigns.room_id ->
        Egghead.chat(socket.assigns.room_id, full_message)
        {:noreply, socket}

      true ->
        {:noreply, assign(socket, chat_status: "No chat room available.")}
    end
  end

  def handle_event("chat_paste", %{"text" => text}, socket) do
    chip = build_paste_chip(text, socket.assigns.paste_chips)
    chips = socket.assigns.paste_chips ++ [chip]
    {:noreply, assign(socket, paste_chips: chips)}
  end

  def handle_event("open_paste_modal", %{"id" => id}, socket) do
    {:noreply, assign(socket, active_paste_chip: String.to_integer(id))}
  end

  def handle_event("close_paste_modal", _, socket) do
    {:noreply, assign(socket, active_paste_chip: nil)}
  end

  def handle_event("remove_paste_chip", %{"id" => id}, socket) do
    chip_id = String.to_integer(id)
    chips = Enum.reject(socket.assigns.paste_chips, &(&1.id == chip_id))
    {:noreply, assign(socket, paste_chips: chips, active_paste_chip: nil)}
  end

  def handle_event("toggle_agents", _, socket) do
    {:noreply, assign(socket, show_agents: !socket.assigns.show_agents)}
  end

  def handle_event("toggle_rooms_menu", _, socket) do
    {:noreply, assign(socket, rooms_menu_open: !socket.assigns.rooms_menu_open)}
  end

  # Switch the chat window to a different room. Same path as /join —
  # the target may be an existing room, a transcript record, or a
  # brand-new room name (which will be created). Always closes the
  # rooms dropdown.
  def handle_event("switch_chat_room", %{"room" => target}, socket) do
    socket = assign(socket, rooms_menu_open: false)

    case resolve_join_target(target) do
      {:ok, room_id} ->
        {:noreply, switch_active_room(socket, room_id)}

      {:error, reason} ->
        {:noreply,
         append_entry(
           socket,
           Egghead.TUI.Chat.Entry.system("Cannot switch to #{inspect(target)}: #{reason}")
         )}
    end
  end

  # Drop a room: stop the GenServer (with transcript save) and remove
  # it from the system. If it was the active room, room_stopped PubSub
  # will land and bounce us back to the default room. The default room
  # itself can't be dropped.
  def handle_event("drop_chat_room", %{"room" => room}, socket) do
    default = Egghead.default_room()

    if room == default do
      {:noreply, socket}
    else
      Task.Supervisor.start_child(Egghead.Tool.TaskSupervisor, fn ->
        Egghead.stop_room(room, no_save: false)
      end)

      {:noreply, assign(socket, rooms_menu_open: false)}
    end
  end

  # --- PubSub: record changes ---

  @impl true
  def handle_info({:record_changed, _id}, socket) do
    all = Egghead.list_records() |> Enum.sort_by(&(&1.updated || ""), :desc)

    socket =
      socket
      |> assign(all: all)
      |> apply_filter()
      |> hydrate_selection()
      |> push_chat_corpus()

    {:noreply, socket}
  end

  # Send the chat-completion candidate corpus to the JS hook. This is
  # the only thing the server tells the client about completion —
  # filtering, popover state, arrow nav, and acceptance all happen
  # browser-side.
  def handle_info(:push_chat_corpus, socket) do
    {:noreply, push_chat_corpus(socket)}
  end

  # --- PubSub: chat room events ---

  def handle_info({:user_message, msg}, socket) do
    entry = Egghead.TUI.Chat.Entry.user(msg.sender.name, msg.content)
    {:noreply, append_entry(socket, entry)}
  end

  def handle_info({:agent_message, msg}, socket) do
    socket =
      socket
      |> finalize_stream(msg.sender.id)
      |> set_agent_status(msg.sender.id, :idle)
      |> update_agent_ctx(msg.sender.id, msg)

    {:noreply, socket}
  end

  def handle_info({:agent_streaming, _room_id, agent_id, delta}, socket) do
    socket = socket |> apply_stream_delta(agent_id, delta) |> set_agent_status(agent_id, :active)
    # Start the typing animation timer if not already running
    socket = maybe_start_anim_timer(socket)
    {:noreply, socket}
  end

  def handle_info(:tick_anim, socket) do
    if map_size(socket.assigns.active_streams) > 0 do
      Process.send_after(self(), :tick_anim, 400)
      {:noreply, assign(socket, anim_frame: socket.assigns.anim_frame + 1)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:agent_tool_call, _room_id, agent_id, tool_name, input}, socket) do
    display = agent_display_name(agent_id)
    text = format_tool_call(tool_name, input)
    entry = Egghead.TUI.Chat.Entry.action(agent_id, display, text)

    # Flush any in-progress streamed text before the action line so that
    # post-tool text doesn't concatenate onto pre-tool text.
    socket = finalize_stream(socket, agent_id)
    {:noreply, append_entry(socket, entry)}
  end

  def handle_info(
        {:agent_tool_denied, _room_id, agent_id, tool_name, input, denial},
        socket
      ) do
    display = agent_display_name(agent_id)
    text = format_denial(agent_id, tool_name, input, denial)
    entry = Egghead.TUI.Chat.Entry.denial(agent_id, display, text, denial)
    socket = finalize_stream(socket, agent_id)
    {:noreply, append_entry(socket, entry)}
  end

  def handle_info(
        {:agent_tool_output, _room_id, agent_id, tool_name, _tool_use_id, chunk},
        socket
      ) do
    trimmed = String.trim_trailing(chunk)

    if trimmed == "" do
      {:noreply, socket}
    else
      display = agent_display_name(agent_id)

      entry = %Egghead.TUI.Chat.Entry{
        kind: :action,
        sender_id: agent_id,
        sender_name: display,
        text: "#{tool_name}: #{trimmed}",
        timestamp: DateTime.utc_now(),
        metadata: %{tool_output: true}
      }

      {:noreply, append_entry(socket, entry)}
    end
  end

  def handle_info({:agents_activated, _count}, socket), do: {:noreply, socket}

  def handle_info({:agent_passed, agent_id}, socket) do
    display = agent_display_name(agent_id)
    # Random flavor per /pass event. The picked text is stored on the
    # Entry so re-renders use the same string deterministically.
    flavor = Egghead.Chat.PassActions.pick()
    entry = Egghead.TUI.Chat.Entry.action(agent_id, display, flavor)
    {:noreply, socket |> drop_stream(agent_id) |> append_entry(entry)}
  end

  def handle_info(:budget_exhausted, socket) do
    {:noreply,
     assign(socket,
       chat_status: "Paused for you. /continue to resume, or send a message."
     )}
  end

  def handle_info({:continued, opts}, socket) do
    case Keyword.get(opts, :replayed, 0) do
      0 -> {:noreply, assign(socket, chat_status: "The room is quiet.")}
      _ -> {:noreply, assign(socket, chat_status: nil)}
    end
  end

  def handle_info({:agent_joined, agent_id}, socket) do
    entry = Egghead.TUI.Chat.Entry.system("#{agent_display_name(agent_id)} joined")

    {:noreply,
     socket
     |> append_entry(entry)
     |> assign(agents: hydrate_agents_for_room(socket.assigns.room_id))
     |> push_chat_corpus()}
  end

  def handle_info({:agent_left, agent_id}, socket) do
    entry = Egghead.TUI.Chat.Entry.system("#{agent_display_name(agent_id)} left")

    {:noreply,
     socket
     |> append_entry(entry)
     |> assign(agents: hydrate_agents_for_room(socket.assigns.room_id))
     |> push_chat_corpus()}
  end

  # Coordinator broadcasts this whenever the room's roster changes
  # via lifecycle events (agent started / stopped). Re-hydrate so
  # placeholder ids get real display names.
  def handle_info({:agent_roster_changed}, socket) do
    {:noreply, assign(socket, agents: hydrate_agents_for_room(socket.assigns.room_id))}
  end

  def handle_info({:agent_handoff_started, _room_id, agent_id}, socket) do
    entry =
      Egghead.TUI.Chat.Entry.system("#{agent_display_name(agent_id)} is summarising context…")

    {:noreply,
     socket
     |> append_entry(entry)
     |> set_agent_status(agent_id, :handoff)}
  end

  def handle_info({:agent_handoff, _room_id, agent_id, delib_id}, socket) do
    entry =
      Egghead.TUI.Chat.Entry.system(
        "#{agent_display_name(agent_id)} is back with fresh context — saved [[#{delib_id}]]"
      )

    {:noreply,
     socket
     |> append_entry(entry)
     |> set_agent_status(agent_id, :idle)}
  end

  def handle_info({:system_notice, text}, socket) do
    {:noreply, append_entry(socket, Egghead.TUI.Chat.Entry.system(text))}
  end

  def handle_info({:agent_mentions, _room_id, _from, _to, _content}, socket),
    do: {:noreply, socket}

  def handle_info({:room_stopped, room_id}, socket) do
    socket = push_chat_corpus(socket)

    if room_id == socket.assigns.room_id do
      {:noreply, push_patch(socket, to: ~p"/chat/#{Egghead.default_room()}")}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # --- Private: records ---

  defp apply_filter(socket) do
    records = socket.assigns.all
    query = socket.assigns.query
    classes = socket.assigns.class_filter

    filtered =
      records
      |> filter_by_class(classes)
      |> filter_by_query(query)

    assign(socket, filtered: filtered)
  end

  defp filter_by_class(records, classes) do
    Enum.filter(records, &MapSet.member?(classes, &1.class))
  end

  defp filter_by_query(records, ""), do: records

  defp filter_by_query(records, query) do
    needle = String.downcase(query)

    Enum.filter(records, fn r ->
      String.contains?(String.downcase(r.id || ""), needle) or
        String.contains?(String.downcase(r.title || ""), needle)
    end)
  end

  # Search-window footer label. "N records" when no filter or query is
  # active, "N of TOTAL" when filtering down. The full class set is the
  # implicit "no filter" baseline (mounts with all classes enabled).
  defp search_count_label(filtered, all, query, class_filter) do
    fcount = length(filtered)
    total = length(all)
    full_classes = MapSet.size(class_filter) == 5

    if query == "" and full_classes do
      "#{total} #{pluralize(total, "record")}"
    else
      "#{fcount} of #{total}"
    end
  end

  defp pluralize(1, word), do: word
  defp pluralize(_, word), do: word <> "s"

  defp creation_target(query, filtered) do
    title = String.trim(query)

    if title == "" do
      nil
    else
      slug = Slug.slugify(title)

      cond do
        slug == "" -> nil
        Enum.any?(filtered, &(&1.id == slug)) -> nil
        true -> {title, slug}
      end
    end
  end

  defp hydrate_selection(socket) do
    case socket.assigns.selected_id do
      nil ->
        socket

      id ->
        case Egghead.get_record(id) do
          {:ok, record} ->
            html = render_record_body(record)

            backlinks = Egghead.find_backlinks(id)

            word_count =
              case record.body do
                nil -> 0
                body -> body |> String.split(~r/\s+/, trim: true) |> length()
              end

            assign(socket,
              selected_record: record,
              selected_body_html: html,
              backlinks: backlinks,
              word_count: word_count
            )

          {:error, _} ->
            assign(socket,
              selected_record: nil,
              selected_body_html: nil,
              backlinks: [],
              word_count: 0
            )
        end
    end
  end

  defp record_exists?(id) do
    case Egghead.get_record(id) do
      {:ok, _} -> true
      _ -> false
    end
  end

  # Dispatch on the record's on-disk format. Org records use `OrgHTML` so the
  # rendered output preserves headline stars, TODO keywords, drawer entries,
  # and `#+BEGIN_SRC` markers — what an emacs user expects to see.
  defp render_record_body(%{format: :org, body: body}) do
    OrgHTML.render(body || "",
      link_fn: &"/records/#{&1}",
      exists_fn: &record_exists?/1
    )
  end

  defp render_record_body(%{body: body}) do
    MarkdownHTML.render(body || "",
      link_fn: &"/records/#{&1}",
      exists_fn: &record_exists?/1
    )
  end

  defp build_file_tree(records) do
    records
    |> Enum.group_by(fn r ->
      case String.split(r.id || "", "/") do
        [_single] -> ""
        parts -> parts |> Enum.drop(-1) |> Enum.join("/")
      end
    end)
    |> Enum.sort_by(fn {dir, _} -> dir end)
  end

  # --- Private: chat ---

  # Translate a Room.Message map into the right Entry kind for the
  # chat view. `/pass` messages render as `/me`-style action lines
  # (matching the live-event handler in `:agent_passed`); everything
  # else maps to its sender type.
  defp message_to_entry(%{sender: %{type: :user, name: name}, content: content}) do
    Egghead.TUI.Chat.Entry.user(name, content)
  end

  defp message_to_entry(%{
         id: msg_id,
         sender: %{type: :agent, id: id, name: name},
         content: "/pass"
       }) do
    # Use the message id as the seed so each /pass event picks the same
    # flavor across reloads — different events get different flavors.
    flavor = Egghead.Chat.PassActions.pick(msg_id)
    Egghead.TUI.Chat.Entry.action(id, name, flavor)
  end

  defp message_to_entry(%{sender: %{type: :agent, id: id, name: name}, content: content}) do
    Egghead.TUI.Chat.Entry.agent(id, name, content)
  end

  # Swap which chat room is active. Unsubscribes the old room, marks
  # the new one active, drops streaming/dropdown state, and rehydrates
  # transcript from the new room's GenServer.
  defp switch_active_room(socket, room_id) do
    if socket.assigns.active_chat_room == room_id do
      socket
    else
      socket
      |> unsubscribe_room(socket.assigns.active_chat_room)
      |> assign(
        active_chat_room: room_id,
        room_id: room_id,
        transcript: [],
        active_streams: %{},
        chat_status: nil,
        chat_input: "",
        paste_chips: [],
        active_paste_chip: nil
      )
      |> hydrate_chat()
    end
  end

  defp hydrate_chat(socket) do
    case socket.assigns.room_id do
      nil ->
        socket

      room_id ->
        if connected?(socket) do
          Egghead.Chat.Room.subscribe(room_id)
        end

        # Room.get_transcript/1 returns the message list directly (not
        # `{:ok, messages}`). Wrap in try so a dead room degrades to an
        # empty transcript rather than crashing the LiveView.
        transcript =
          try do
            room_id
            |> Egghead.Chat.Room.get_transcript()
            |> Enum.map(&message_to_entry/1)
          catch
            _, _ -> []
          end

        assign(socket,
          transcript: transcript,
          agents: hydrate_agents_for_room(room_id)
        )
    end
  end

  # The roster shows agents that are members of the *current room*,
  # not every agent the system knows about. Pull the room's member
  # list from its GenServer state and join with `list_agents/0` for
  # display info; agents in the room but not yet in `list_agents`
  # render under their bare id until they materialise.
  defp hydrate_agents_for_room(nil), do: []

  defp hydrate_agents_for_room(room_id) do
    member_ids =
      try do
        room_id
        |> Egghead.Chat.Room.get_state()
        |> Map.get(:agents, [])
      catch
        _, _ -> []
      end

    running_by_id =
      try do
        Egghead.list_agents() |> Map.new(&{&1.id, &1})
      catch
        _, _ -> %{}
      end

    Enum.map(member_ids, fn id ->
      base = %{
        id: id,
        name: id,
        status: :idle,
        ctx_pct: 0.0,
        ctx_window: 0,
        ctx_tokens: 0
      }

      case Map.get(running_by_id, id) do
        %{name: name} when is_binary(name) and name != "" -> %{base | name: name}
        _ -> base
      end
    end)
  end

  # Buffer streaming deltas via the shared Chat.Stream module.
  # LiveView renders bubble-style: commit on \n\n (paragraph), trim
  # each committed paragraph. Single \n within a paragraph renders
  # as a line break inside the bubble.
  defp apply_stream_delta(socket, agent_id, delta) do
    streams = socket.assigns.active_streams
    name = agent_display_name(agent_id)

    stream =
      Map.get_lazy(streams, agent_id, fn ->
        Egghead.Chat.Stream.new(agent_id, name, commit_on: "\n\n", trim: true)
      end)

    {stream, committed} = Egghead.Chat.Stream.append(stream, delta)

    socket
    |> assign(active_streams: Map.put(streams, agent_id, stream))
    |> append_entries(committed)
  end

  # Flush whatever's buffered for the agent and drop the stream in
  # one atomic step. Fused so a future edit can't reintroduce the
  # "commit-without-clear" concat bug.
  defp finalize_stream(socket, agent_id) do
    {streams, committed} =
      Egghead.Chat.Stream.finalize_and_drop(socket.assigns.active_streams, agent_id)

    socket
    |> assign(active_streams: streams)
    |> append_entries(committed)
  end

  defp drop_stream(socket, agent_id) do
    assign(socket, active_streams: Map.delete(socket.assigns.active_streams, agent_id))
  end

  defp append_entry(socket, entry) do
    assign(socket, transcript: socket.assigns.transcript ++ [entry])
  end

  defp broadcast_system_notice(room_id, text) do
    Phoenix.PubSub.broadcast(
      Egghead.PubSub,
      Egghead.Chat.Room.topic(room_id),
      {:system_notice, text}
    )
  end

  defp append_entries(socket, []), do: socket

  defp append_entries(socket, entries) do
    assign(socket, transcript: socket.assigns.transcript ++ entries)
  end

  defp agent_display_name(agent_id) do
    agent_id |> String.split("/") |> List.last() |> String.capitalize()
  end

  defp maybe_start_anim_timer(socket) do
    # Only start if we don't already have active streams (first stream arrival)
    if map_size(socket.assigns.active_streams) <= 1 do
      Process.send_after(self(), :tick_anim, 400)
    end

    socket
  end

  defp typing_indicator(anim_frame) do
    String.duplicate("\u00B7", rem(anim_frame, 3) + 1)
  end

  defp typing_agents(streams) do
    streams
    |> Enum.filter(fn {_id, s} -> Egghead.Chat.Stream.has_text?(s) end)
    |> Enum.sort_by(fn {_id, s} -> s.started_at end)
    |> Enum.map(fn {_id, s} -> {s.name, s.agent_id} end)
  end

  defp render_entry_html(%Egghead.TUI.Chat.Entry{text: text}) do
    MarkdownHTML.render(text)
  end

  @valid_room_name ~r/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/

  # Resolve a `/join` argument to a room id. Tries, in order:
  # (1) a live room with that exact id; (2) a saved transcript record;
  # (3) create a new room with that name (IRC semantics).
  defp resolve_join_target(target) do
    cond do
      Egghead.room_exists?(target) ->
        {:ok, target}

      true ->
        candidate = if String.starts_with?(target, "chat/"), do: target, else: "chat/#{target}"

        case Egghead.Chat.Room.from_transcript(candidate) do
          {:ok, room_id} ->
            {:ok, room_id}

          {:error, :not_found} ->
            create_room_if_valid(target)

          {:error, :wrong_class} ->
            {:error, "record exists but is not a transcript"}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
    end
  end

  defp create_room_if_valid(name) do
    cond do
      String.length(name) > 64 ->
        {:error, "room name too long (max 64 characters)"}

      not Regex.match?(@valid_room_name, name) ->
        {:error, "room name must be alphanumeric (hyphens and underscores allowed)"}

      true ->
        case Egghead.create_room(id: name) do
          {:ok, room_id} -> {:ok, room_id}
          {:error, reason} -> {:error, "could not create room: #{inspect(reason)}"}
        end
    end
  end

  # --- Slash commands ---

  @chat_commands %{
    "save" => :cmd_save,
    "copy" => :cmd_copy,
    "continue" => :cmd_continue,
    "halt" => :cmd_halt,
    "stop" => :cmd_halt,
    "handoff" => :cmd_handoff,
    "join" => :cmd_join,
    "list" => :cmd_list,
    "rooms" => :cmd_list,
    "drop" => :cmd_drop,
    "mute" => :cmd_mute,
    "unmute" => :cmd_unmute,
    "invite" => :cmd_invite,
    "kick" => :cmd_kick,
    "whois" => :cmd_whois,
    "tools" => :cmd_tools,
    "mcp" => :cmd_mcp,
    "help" => :cmd_help
  }

  @chat_command_list [
    %{name: "save", description: "Save transcript as a record"},
    %{name: "copy", description: "Copy transcript to clipboard"},
    %{name: "continue", description: "Grant agents more turns"},
    %{name: "halt", description: "Interrupt agents mid-turn"},
    %{name: "handoff", description: "Handoff an agent's context (space opens picker)"},
    %{name: "join", description: "Join or create a room (space opens picker)"},
    %{name: "list", description: "List all open rooms"},
    %{name: "drop", description: "Drop the current room"},
    %{name: "mute", description: "Mute an agent (space opens picker)"},
    %{name: "unmute", description: "Unmute a muted agent (space opens picker)"},
    %{name: "invite", description: "Invite an agent into this room (space opens picker)"},
    %{name: "kick", description: "Evict an agent from this room (space opens picker)"},
    %{
      name: "whois",
      description: "Show an agent's model, capabilities, rooms (space opens picker)"
    },
    %{name: "tools", description: "Summary of tools available to agents"},
    %{name: "mcp", description: "Summary of MCP servers"},
    %{name: "help", description: "Show keybindings & commands"}
  ]

  defp dispatch_slash_command(text, socket) do
    [raw_cmd | args] =
      text
      |> String.trim_leading("/")
      |> String.split(" ", parts: 2)

    cmd_name = String.downcase(raw_cmd)
    arg = List.first(args, "")

    case Map.get(@chat_commands, cmd_name) do
      nil ->
        append_entry(socket, Egghead.TUI.Chat.Entry.system("Unknown command: /#{cmd_name}"))

      :cmd_save ->
        if socket.assigns.room_id do
          # `Egghead.chat_save/1` hits the Room GenServer and writes the
          # transcript to disk. Disk I/O is usually fast but can stall;
          # run it on a supervised Task so the LiveView process stays
          # free for input and PubSub events. Outcome broadcasts as a
          # `:system_notice` — the existing PubSub handler renders it.
          room_id = socket.assigns.room_id

          Task.Supervisor.start_child(Egghead.Tool.TaskSupervisor, fn ->
            case Egghead.chat_save(room_id) do
              {:ok, record_id} ->
                broadcast_system_notice(
                  room_id,
                  "Transcript saved \u2192 [[#{record_id}]]"
                )

              {:error, reason} ->
                broadcast_system_notice(room_id, "Save failed: #{inspect(reason)}")

              _ ->
                broadcast_system_notice(room_id, "Save failed")
            end
          end)

          socket
        else
          socket
        end

      :cmd_continue ->
        if socket.assigns.room_id do
          Egghead.chat_continue(socket.assigns.room_id)

          append_entry(
            socket,
            Egghead.TUI.Chat.Entry.system("Budget renewed \u2014 agents may continue")
          )
        else
          socket
        end

      :cmd_handoff ->
        target = String.trim(arg)

        cond do
          target == "" ->
            append_entry(socket, Egghead.TUI.Chat.Entry.system("Usage: /handoff <agent>"))

          socket.assigns.room_id == nil ->
            append_entry(
              socket,
              Egghead.TUI.Chat.Entry.system("/handoff requires an active room")
            )

          true ->
            room_id = socket.assigns.room_id

            socket =
              append_entry(
                socket,
                Egghead.TUI.Chat.Entry.system("Handoff initiated for #{target}…")
              )

            # Run under Task.Supervisor so crashes log via OTP instead
            # of vanishing. Outcome broadcasts as a `:system_notice` on
            # the room topic so every subscriber (this LiveView, the
            # TUI, MCP watchers) sees the same result — and this
            # LiveView receives it via its PubSub subscription, not a
            # direct `send/2`.
            Task.Supervisor.start_child(Egghead.Tool.TaskSupervisor, fn ->
              case Egghead.handoff(target, room_id: room_id) do
                {:ok, delib_id} ->
                  broadcast_system_notice(
                    room_id,
                    "Handoff complete for #{target} \u2014 saved [[#{delib_id}]]"
                  )

                {:ok, delib_id, _response} ->
                  broadcast_system_notice(
                    room_id,
                    "Handoff complete for #{target} \u2014 saved [[#{delib_id}]]"
                  )

                {:error, reason} ->
                  broadcast_system_notice(
                    room_id,
                    "Handoff failed for #{target}: #{inspect(reason)}"
                  )
              end
            end)

            socket
        end

      :cmd_join ->
        target = String.trim(arg)

        cond do
          target == "" ->
            append_entry(
              socket,
              Egghead.TUI.Chat.Entry.system("Usage: /join <room-id-or-transcript-id>")
            )

          target == socket.assigns.room_id ->
            append_entry(socket, Egghead.TUI.Chat.Entry.system("Already in #{target}"))

          true ->
            case resolve_join_target(target) do
              {:ok, room_id} ->
                push_patch(socket, to: ~p"/chat/#{room_id}")

              {:error, reason} ->
                append_entry(
                  socket,
                  Egghead.TUI.Chat.Entry.system("Cannot join #{inspect(target)}: #{reason}")
                )
            end
        end

      :cmd_list ->
        rooms = Egghead.list_rooms()
        default = Egghead.default_room()

        lines =
          if rooms == [] do
            ["No rooms open."]
          else
            Enum.map(rooms, fn id ->
              marker = if id == default, do: " (default)", else: ""

              info =
                try do
                  state = Egghead.Chat.Room.get_state(id)
                  agents = length(state.agents || [])
                  msgs = state.message_count || 0
                  " — #{agents} agents, #{msgs} messages"
                catch
                  _, _ -> ""
                end

              "  #{id}#{marker}#{info}"
            end)
          end

        text = ["Rooms:" | lines] |> Enum.join("\n")
        append_entry(socket, Egghead.TUI.Chat.Entry.system(text))

      :cmd_drop ->
        no_save = String.contains?(arg, "--no-save")
        room_id = socket.assigns.room_id

        cond do
          room_id == Egghead.default_room() ->
            append_entry(
              socket,
              Egghead.TUI.Chat.Entry.system("Cannot drop the default room.")
            )

          true ->
            Task.Supervisor.start_child(Egghead.Tool.TaskSupervisor, fn ->
              Egghead.stop_room(room_id, no_save: no_save)
            end)

            push_patch(socket, to: ~p"/chat/#{Egghead.default_room()}")
        end

      :cmd_mute ->
        target = String.trim(arg)

        if target == "" do
          append_entry(socket, Egghead.TUI.Chat.Entry.system("Usage: /mute <agent>"))
        else
          Egghead.Chat.Room.mute(socket.assigns.room_id, target)
          socket
        end

      :cmd_unmute ->
        target = String.trim(arg)

        if target == "" do
          append_entry(socket, Egghead.TUI.Chat.Entry.system("Usage: /unmute <agent>"))
        else
          Egghead.Chat.Room.unmute(socket.assigns.room_id, target)
          socket
        end

      :cmd_copy ->
        # Push the formatted transcript to the browser; a small JS
        # handler in ChatInput writes it to the clipboard. The
        # synthesised transcript is what's currently in the room
        # GenServer (same source the TUI's /copy uses).
        if socket.assigns.room_id do
          room_id = socket.assigns.room_id

          msgs =
            try do
              Egghead.Chat.Room.get_transcript(room_id)
            catch
              _, _ -> []
            end

          case msgs do
            [] ->
              append_entry(socket, Egghead.TUI.Chat.Entry.system("Transcript is empty"))

            list ->
              body = Egghead.Chat.Room.format_transcript(list)

              socket
              |> push_event("chat_copy", %{text: body})
              |> append_entry(Egghead.TUI.Chat.Entry.system("Transcript copied to clipboard"))
          end
        else
          socket
        end

      :cmd_halt ->
        if socket.assigns.room_id do
          room_id = socket.assigns.room_id

          Task.Supervisor.start_child(Egghead.Tool.TaskSupervisor, fn ->
            try do
              Egghead.chat_halt(room_id)
            catch
              _, _ -> :ok
            end
          end)

          append_entry(
            socket,
            Egghead.TUI.Chat.Entry.system(
              "Halt requested — agents will stop after their current step"
            )
          )
        else
          socket
        end

      :cmd_invite ->
        target = String.trim(arg)

        cond do
          target == "" ->
            append_entry(socket, Egghead.TUI.Chat.Entry.system("Usage: /invite <agent>"))

          socket.assigns.room_id == nil ->
            append_entry(socket, Egghead.TUI.Chat.Entry.system("/invite requires an active room"))

          true ->
            do_invite(target, socket.assigns.room_id, socket)
        end

      :cmd_kick ->
        target = String.trim(arg)

        cond do
          target == "" ->
            append_entry(socket, Egghead.TUI.Chat.Entry.system("Usage: /kick <agent>"))

          socket.assigns.room_id == nil ->
            append_entry(socket, Egghead.TUI.Chat.Entry.system("/kick requires an active room"))

          true ->
            do_kick(target, socket.assigns.room_id, socket)
        end

      :cmd_whois ->
        target = String.trim(arg)

        if target == "" do
          append_entry(socket, Egghead.TUI.Chat.Entry.system("Usage: /whois <agent>"))
        else
          append_entry(socket, Egghead.TUI.Chat.Entry.system(format_whois(target)))
        end

      :cmd_tools ->
        append_entry(
          socket,
          Egghead.TUI.Chat.Entry.system(Egghead.TUI.ToolCatalog.tools_summary())
        )

      :cmd_mcp ->
        append_entry(
          socket,
          Egghead.TUI.Chat.Entry.system(Egghead.TUI.ToolCatalog.mcp_summary())
        )

      :cmd_help ->
        socket
        |> append_entry(
          Egghead.TUI.Chat.Entry.system(
            "Commands: /save /copy /continue /halt /handoff <agent> /join <room> /list /drop /mute <agent> /unmute <agent> /invite <agent> /kick <agent> /whois <agent> /tools /mcp /help"
          )
        )
        |> append_entry(
          Egghead.TUI.Chat.Entry.system(
            "Enter send | Shift+Enter newline | @agent mention | \\[\\[record\\]\\] link | Tab accept"
          )
        )
    end
  end

  # ---- /invite, /kick, /whois helpers (web-side adaptation of TUI) ----

  defp do_invite(agent_id, room_id, socket) do
    in_room =
      try do
        room_id |> Egghead.Chat.Room.get_state() |> Map.get(:agents, []) |> MapSet.new()
      catch
        _, _ -> MapSet.new()
      end

    cond do
      MapSet.member?(in_room, agent_id) ->
        append_entry(
          socket,
          Egghead.TUI.Chat.Entry.system("#{agent_id} is already in this room.")
        )

      true ->
        case resolve_invite_record(agent_id) do
          {:error, reason} ->
            append_entry(socket, Egghead.TUI.Chat.Entry.system("/invite: #{reason}"))

          {:ok, record} ->
            Task.Supervisor.start_child(Egghead.Tool.TaskSupervisor, fn ->
              ensure_agent_started(record)
              Egghead.Chat.Room.join(room_id, agent_id)
              broadcast_system_notice(room_id, "#{agent_id} invited")
            end)

            socket
        end
    end
  end

  defp do_kick(agent_id, room_id, socket) do
    members =
      try do
        room_id |> Egghead.Chat.Room.get_state() |> Map.get(:agents, []) |> MapSet.new()
      catch
        _, _ -> MapSet.new()
      end

    default = Egghead.default_room()

    cond do
      not MapSet.member?(members, agent_id) ->
        append_entry(
          socket,
          Egghead.TUI.Chat.Entry.system("#{agent_id} is not in this room.")
        )

      room_id == default and MapSet.size(members) == 1 ->
        append_entry(
          socket,
          Egghead.TUI.Chat.Entry.system("Cannot kick the last agent from the default room.")
        )

      true ->
        Task.Supervisor.start_child(Egghead.Tool.TaskSupervisor, fn ->
          Egghead.Chat.Room.leave(room_id, agent_id)
          _ = Egghead.Agent.drop_session(agent_id, room_id)
          broadcast_system_notice(room_id, "#{agent_id} kicked")
        end)

        socket
    end
  end

  defp resolve_invite_record(agent_id), do: Egghead.Agent.resolve_for_invite(agent_id)

  defp ensure_agent_started(record) do
    name = Egghead.Agent.agent_name(record.id)

    case GenServer.whereis(name) do
      nil ->
        case Egghead.Agent.Supervisor.start_agent(record) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, _reason} -> :ok
        end

      _pid ->
        :ok
    end
  end

  defp format_whois(agent_id) do
    info =
      try do
        Egghead.list_agents() |> Enum.find(&(&1.id == agent_id))
      catch
        _, _ -> nil
      end

    record =
      case Egghead.get_record(agent_id) do
        {:ok, _} -> {:ok, agent_id}
        _ -> if agent_id == "index", do: :builtin, else: :missing
      end

    rooms =
      try do
        Egghead.list_rooms()
        |> Enum.filter(fn rid ->
          members =
            try do
              rid |> Egghead.Chat.Room.get_state() |> Map.get(:agents, []) |> MapSet.new()
            catch
              _, _ -> MapSet.new()
            end

          MapSet.member?(members, agent_id)
        end)
      catch
        _, _ -> []
      end

    header =
      case record do
        {:ok, _} -> "#{agent_id} — [[#{agent_id}]]"
        :builtin -> "#{agent_id} (built-in — no backing record)"
        :missing -> "#{agent_id} (no backing record)"
      end

    model_line =
      case info do
        %{model: m} when is_binary(m) and m != "" -> "  model: #{m}"
        _ -> "  model: (not running)"
      end

    caps_line =
      case info do
        %{capabilities: caps} when is_list(caps) and caps != [] ->
          "  caps: #{caps |> Enum.map(&Egghead.Capability.grant_to_spec/1) |> Enum.join(", ")}"

        %{capabilities: _} ->
          "  caps: (none)"

        _ ->
          "  caps: (not running)"
      end

    rooms_line =
      case rooms do
        [] -> "  rooms: (none)"
        list -> "  rooms: #{Enum.join(list, ", ")}"
      end

    Enum.join([header, model_line, caps_line, rooms_line], "\n")
  end

  # --- Paste chips ---

  defp build_paste_chip(text, existing) do
    id = next_chip_id(existing)
    lines = text |> String.split("\n") |> length()

    first_line =
      text |> String.split("\n") |> Enum.find("", &(String.trim(&1) != "")) |> String.trim()

    head =
      if String.length(first_line) > 25 do
        String.slice(first_line, 0, 25) <> "\u2026"
      else
        first_line
      end

    %{
      id: id,
      head: head,
      extra_lines: lines - 1,
      char_count: String.length(text),
      full_text: text
    }
  end

  defp next_chip_id([]), do: 1

  defp next_chip_id(existing) do
    existing |> Enum.map(& &1.id) |> Enum.max() |> Kernel.+(1)
  end

  # --- Transcript rendering helpers ---

  # Collapse consecutive nicks: don't repeat sender name when
  # same sender + same kind in sequence
  defp collapse_nicks(entries) do
    entries
    |> Enum.reduce({{nil, nil}, []}, fn entry, {{prev_id, prev_kind}, acc} ->
      same? = entry.sender_id == prev_id and entry.sender_id != nil and entry.kind == prev_kind
      {{entry.sender_id || prev_id, entry.kind}, [{entry, !same?} | acc]}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # Group consecutive agent entries from the same sender into runs
  # for unified markdown rendering

  defp set_agent_status(socket, agent_id, status) do
    agents =
      Enum.map(socket.assigns.agents, fn
        %{id: ^agent_id} = a -> %{a | status: status}
        a -> a
      end)

    assign(socket, agents: agents)
  end

  defp update_agent_ctx(socket, agent_id, msg) do
    case Map.get(msg, :usage) do
      %{context_window: cw, current_context_tokens: cct} when is_integer(cw) and cw > 0 ->
        pct = Float.round(cct / cw * 100, 1)

        agents =
          Enum.map(socket.assigns.agents, fn
            %{id: ^agent_id} = a ->
              %{a | ctx_pct: pct, ctx_window: cw, ctx_tokens: cct}

            a ->
              a
          end)

        assign(socket, agents: agents)

      _ ->
        socket
    end
  end

  defp format_tool_call(name, input) when is_map(input) do
    summary =
      input
      |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v, limit: 3, printable_limit: 40)}" end)
      |> Enum.join(" ")

    "uses #{name} #{summary}" |> String.trim()
  end

  defp format_tool_call(name, _), do: "uses #{name}"

  defp format_denial(agent_id, tool_name, input, denial) do
    input_summary =
      case input do
        %{} = m ->
          m
          |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v, limit: 3, printable_limit: 40)}" end)
          |> Enum.join(" ")

        _ ->
          ""
      end

    tried = String.trim("tried #{tool_name} #{input_summary}")
    reason = "denied (#{denial.code}): #{denial.message}"

    grant_line =
      if denial.suggested_grant do
        "→ egghead agent grant #{agent_id} '#{denial.suggested_grant}'"
      else
        nil
      end

    [tried, reason, grant_line]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp format_tokens(n), do: "#{n}"

  # Pushes the candidate corpus (commands, agents, broadcast tokens,
  # recent records, rooms) to the browser. The ChatInput JS hook
  # stores this and uses it to drive a fully client-side completion
  # popover — including second-argument pickers for `/mute <agent>`,
  # `/handoff <agent>`, `/join <room>`, etc.
  defp push_chat_corpus(socket) do
    if connected?(socket) do
      agents =
        try do
          Egghead.list_agents()
          |> Enum.map(&%{id: &1.id, name: &1.name})
        catch
          _, _ -> []
        end

      broadcasts =
        Egghead.TUI.Chat.Mentions.broadcast_tokens()
        |> Enum.map(&%{id: &1.id, name: &1.name, label: &1.label, broadcast: true})

      records =
        try do
          Egghead.recent(limit: 200)
          |> Enum.map(&%{id: &1.id, title: &1.title})
        catch
          _, _ -> []
        end

      rooms =
        try do
          default = Egghead.default_room()

          [default | Egghead.list_rooms()]
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.map(&%{id: &1})
        catch
          _, _ -> []
        end

      push_event(socket, "chat_corpus", %{
        commands: @chat_command_list,
        agents: agents,
        broadcasts: broadcasts,
        records: records,
        rooms: rooms
      })
    else
      socket
    end
  end

  defp format_date(nil), do: nil

  defp format_date(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        Calendar.strftime(dt, "%b %-d, %Y at %-I:%M %p")

      _ ->
        case Date.from_iso8601(iso) do
          {:ok, d} -> Calendar.strftime(d, "%b %-d, %Y")
          _ -> iso
        end
    end
  end

  defp format_date(other), do: inspect(other)

  defp view_label(:tree), do: "Tree"
  defp view_label(_), do: "List"

  # Mirror TUI Records.View.format_time/2 — short relative ("3h", "2d") or ISO date.
  defp format_record_time(nil, _), do: ""

  defp format_record_time(s, :relative) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :second)

        cond do
          diff < 60 -> "#{diff}s"
          diff < 3600 -> "#{div(diff, 60)}m"
          diff < 86_400 -> "#{div(diff, 3600)}h"
          diff < 604_800 -> "#{div(diff, 86_400)}d"
          true -> "#{div(diff, 604_800)}w"
        end

      _ ->
        ""
    end
  end

  defp format_record_time(s, :iso) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d")
      _ -> ""
    end
  end

  # Render-time safe lookup of all rooms — never crashes the LV if the
  # room registry is partially up. Always includes the default room.
  defp list_chat_rooms_safe do
    rooms =
      try do
        Egghead.list_rooms()
      catch
        _, _ -> []
      end

    default = Egghead.default_room() || "default"
    [default | rooms] |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  # Deterministic color for agent nicks
  defp agent_nick_color(sender_id) do
    colors = ["#800000", "#008000", "#000080", "#808000", "#800080", "#008080", "#804000"]
    idx = :erlang.phash2(sender_id || "", length(colors))
    Enum.at(colors, idx)
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    phantom = creation_target(assigns.query, assigns.filtered)
    file_tree = if assigns.nav_view == :tree, do: build_file_tree(assigns.filtered), else: []

    record_title =
      cond do
        assigns.selected_record == nil -> "Records"
        assigns.selected_record.title in [nil, ""] -> assigns.selected_record.id
        true -> assigns.selected_record.title
      end

    record_subtitle =
      case assigns.selected_record do
        nil -> nil
        rec -> rec.id
      end

    # The chat window id is stable across room switches so the window's
    # persisted geom isn't lost every time the user picks a new room
    # from the Rooms menu. The title pivots to whichever room is active.
    chat_window_title = "Chat — " <> (assigns.active_chat_room || "default")

    assigns =
      assigns
      |> assign(:phantom, phantom)
      |> assign(:file_tree, file_tree)
      |> assign(:record_title, record_title)
      |> assign(:record_subtitle, record_subtitle)
      |> assign(:chat_window_title, chat_window_title)

    ~H"""
    <div class="app-shell">
      <div class="desktop" id="desktop">
        <%!-- Deskbar — BeOS-style floating shell. Identity, tray, window list. --%>
        <aside class="deskbar" id="deskbar" phx-hook="Deskbar">
          <div class="deskbar-leaf">
            <span class="deskbar-leaf-label">egghead</span>
          </div>

          <%!-- Deskbar tray — BeOS canon. Live clock + date, plus a
               quiet status row for the record store. The Deskbar's
               original tray held a clock and small applets; this
               keeps that idiom, dropped the inaccurate room/agent
               readouts, and surfaces a number that's actually
               grounded in the data layer. --%>
          <div class="deskbar-tray" id="deskbar-tray" phx-hook="Clock">
            <div class="tray-clock" data-tray-clock>—</div>
            <div class="tray-date" data-tray-date>—</div>
            <div class="tray-divider"></div>
            <div class="tray-row" title="Records in the store">
              <span class="tray-key">records</span>
              <span class="tray-val">{length(@all)}</span>
            </div>
          </div>

          <div class="deskbar-windows" id="deskbar-windows">
            <%!-- Record entry first — it can't be dismissed, so it anchors the list. --%>
            <button
              type="button"
              class="deskbar-entry deskbar-entry-anchor"
              data-window-toggle="record"
              data-window-entry="record"
              title="Record viewer"
            >
              <img src="/assets/icon-document.png" alt="" class="deskbar-entry-icon" />
              <span class="deskbar-entry-label">{@record_title}</span>
            </button>
            <button
              type="button"
              class="deskbar-entry"
              data-window-toggle="search"
              data-window-entry="search"
              title="Search records"
            >
              <img src="/assets/icon-search.png" alt="" class="deskbar-entry-icon" />
              <span class="deskbar-entry-label">Search</span>
            </button>
            <button
              type="button"
              class="deskbar-entry"
              data-window-toggle="chat-window"
              data-window-entry="chat-window"
              title={@chat_window_title}
            >
              <img src="/assets/icon-chat.png" alt="" class="deskbar-entry-icon" />
              <span class="deskbar-entry-label">{@chat_window_title}</span>
            </button>
          </div>
        </aside>
        <%!-- Search window --%>
        <.window
          id="search"
          title="Search"
          role={:panel}
          default_x={8}
          default_y={8}
          default_w={280}
          default_h={720}
          default_z={1}
          open={true}
        >
          <div class="nav-inner">
            <div class="nav-toolbar">
              <%!-- View ▾ — BMenuField picking list/tree --%>
              <div class="menu-field-wrap">
                <button
                  type="button"
                  class={["menu-field", @view_dropdown_open && "toggled"]}
                  phx-click="toggle_view_dropdown"
                  title="Choose how records are listed"
                >
                  <img
                    src={
                      if @nav_view == :tree,
                        do: "/assets/icon-tree.png",
                        else: "/assets/icon-list.png"
                    }
                    alt=""
                    class="menu-field-icon"
                  />
                  <span class="menu-field-label">{view_label(@nav_view)}</span>
                  <span class="menu-field-arrow">▾</span>
                </button>
                <div :if={@view_dropdown_open} class="menu-field-dropdown" role="menu">
                  <div class="menu-field-row">
                    <button
                      type="button"
                      class={["menu-field-item", @nav_view == :search && "is-active"]}
                      phx-click="switch_nav_view"
                      phx-value-view="search"
                    >
                      <span class="menu-field-marker">
                        {if @nav_view == :search, do: "●", else: ""}
                      </span>
                      <img src="/assets/icon-list.png" alt="" class="menu-field-row-icon" />
                      <span class="menu-field-text">List</span>
                    </button>
                  </div>
                  <div class="menu-field-row">
                    <button
                      type="button"
                      class={["menu-field-item", @nav_view == :tree && "is-active"]}
                      phx-click="switch_nav_view"
                      phx-value-view="tree"
                    >
                      <span class="menu-field-marker">
                        {if @nav_view == :tree, do: "●", else: ""}
                      </span>
                      <img src="/assets/icon-tree.png" alt="" class="menu-field-row-icon" />
                      <span class="menu-field-text">Tree</span>
                    </button>
                  </div>
                </div>
              </div>

              <%!-- Filter ▾ — BMenuField with class checkboxes --%>
              <div class="menu-field-wrap class-filter-wrap">
                <button
                  type="button"
                  class={["menu-field", @class_dropdown_open && "toggled"]}
                  phx-click="toggle_class_dropdown"
                  title="Filter by record class"
                >
                  <img src="/assets/icon-filter.png" alt="" class="menu-field-icon" />
                  <span class="menu-field-label">Filter</span>
                  <span :if={MapSet.size(@class_filter) < 5} class="menu-field-badge">
                    {MapSet.size(@class_filter)}
                  </span>
                  <span class="menu-field-arrow">▾</span>
                </button>
                <div :if={@class_dropdown_open} class="menu-field-dropdown class-dropdown" role="menu">
                  <div class="dropdown-actions">
                    <button class="dropdown-link" phx-click="class_select_all">All</button>
                    <button class="dropdown-link" phx-click="class_select_none">None</button>
                  </div>
                  <label
                    :for={c <- [:durable, :agent, :deliberation, :transcript, :inbox]}
                    class="class-option"
                  >
                    <input
                      type="checkbox"
                      checked={MapSet.member?(@class_filter, c)}
                      phx-click="toggle_class"
                      phx-value-class={c}
                    />
                    {c}
                  </label>
                </div>
              </div>

              <div class="toolbar-spacer"></div>

              <%!-- Date format two-state toggle. Mirrors TUI ^t. --%>
              <button
                type="button"
                class="menu-field date-toggle"
                phx-click="toggle_date_format"
                title="Toggle date format (relative / ISO)"
              >
                <span class="menu-field-label">
                  {if @date_format == :relative, do: "rel", else: "iso"}
                </span>
              </button>
            </div>
            <div class="nav-search">
              <form phx-change="search" phx-submit={if @phantom, do: "create_record", else: "search"}>
                <input
                  type="text"
                  name="query"
                  value={@query}
                  placeholder="Search or create..."
                  autocomplete="off"
                  phx-debounce="100"
                />
                <input :if={@phantom} type="hidden" name="title" value={elem(@phantom, 0)} />
              </form>
            </div>

            <%!-- Record list --%>
            <div class="record-list-wrap">
              <%!-- List view --%>
              <ul :if={@nav_view == :search} class="record-list">
                <li
                  :for={record <- @filtered}
                  class={["record-item", record.id == @selected_id && "selected"]}
                  phx-click="select_record"
                  phx-value-id={record.id}
                >
                  <span class="record-title">{record.title || record.id}</span>
                  <span class="record-meta" title={record.updated}>
                    {format_record_time(record.updated, @date_format)}
                  </span>
                </li>
                <li
                  :if={@phantom}
                  class="record-item phantom"
                  phx-click="create_record"
                  phx-value-title={elem(@phantom, 0)}
                >
                  <span class="record-title">Create "{elem(@phantom, 0)}"</span>
                  <span class="record-meta">{elem(@phantom, 1)}</span>
                </li>
              </ul>

              <%!-- Tree view — like `tree` / Windows Explorer --%>
              <div :if={@nav_view == :tree} class="record-list file-tree">
                <%= for {dir, records} <- @file_tree do %>
                  <%= if dir == "" do %>
                    <%!-- Root-level files --%>
                    <div
                      :for={record <- records}
                      class={["tree-file", record.id == @selected_id && "selected"]}
                      phx-click="select_record"
                      phx-value-id={record.id}
                    >
                      <img src="/assets/icon-file.png" alt="" class="tree-icon" />
                      <span class="tree-name">{List.last(String.split(record.id, "/"))}</span>
                    </div>
                  <% else %>
                    <%!-- Directory with toggle --%>
                    <div class="tree-folder-header" phx-click="toggle_folder" phx-value-dir={dir}>
                      <img src="/assets/icon-folder.png" alt="" class="tree-icon" />
                      <span class="tree-name folder-name">{dir}/</span>
                    </div>
                    <div :if={MapSet.member?(@tree_open, dir)} class="tree-children">
                      <div
                        :for={record <- records}
                        class={["tree-file", record.id == @selected_id && "selected"]}
                        phx-click="select_record"
                        phx-value-id={record.id}
                      >
                        <img src="/assets/icon-file.png" alt="" class="tree-icon" />
                        <span class="tree-name">{List.last(String.split(record.id, "/"))}</span>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>
          </div>
          <:footer>
            <span class="status-cell">
              {search_count_label(@filtered, @all, @query, @class_filter)}
            </span>
          </:footer>
        </.window>

        <%!-- Record window (anchor) --%>
        <.window
          id="record"
          title={@record_title}
          subtitle={@record_subtitle}
          role={:anchor}
          default_x={296}
          default_y={8}
          default_w={560}
          default_h={720}
          default_z={3}
          open={true}
          class="window-record"
        >
          <main class="record-pane">
            <div :if={@selected_record} class="record-content">
              <details
                class="properties-block"
                open
                id="properties-disclosure"
                phx-hook="Disclosure"
                data-disclosure-key="properties"
              >
                <summary class="properties-summary">
                  <span class="properties-summary-label">Properties</span>
                  <button
                    class="btn-chrome btn-copy"
                    id="copy-md-btn"
                    phx-hook="CopyMarkdown"
                    data-markdown={@selected_record.body || ""}
                  >
                    <img src="/assets/icon-copy.png" alt="" class="btn-icon" />
                    <span class="btn-label">Copy</span>
                  </button>
                </summary>
                <dl class="properties">
                  <div class="prop-row">
                    <dt>id</dt>
                    <dd class="prop-id">{@selected_record.id}</dd>
                  </div>
                  <div class="prop-row">
                    <dt>class</dt>
                    <dd>
                      <span class={"class-badge #{@selected_record.class}"}>
                        {@selected_record.class}
                      </span>
                    </dd>
                  </div>
                  <div :if={@selected_record.author} class="prop-row">
                    <dt>author</dt>
                    <dd>{@selected_record.author}</dd>
                  </div>
                  <div :if={@selected_record.created} class="prop-row">
                    <dt>created</dt>
                    <dd class="prop-date" title={@selected_record.created}>
                      {format_date(@selected_record.created)}
                    </dd>
                  </div>
                  <div :if={@selected_record.updated} class="prop-row">
                    <dt>updated</dt>
                    <dd class="prop-date" title={@selected_record.updated}>
                      {format_date(@selected_record.updated)}
                    </dd>
                  </div>
                  <div :if={@selected_record.tags != []} class="prop-row">
                    <dt>tags</dt>
                    <dd>
                      <span :for={tag <- @selected_record.tags} class="tag-pill">{tag}</span>
                    </dd>
                  </div>
                  <div :if={Egghead.Record.references(@selected_record) != []} class="prop-row">
                    <dt>links</dt>
                    <dd>
                      <a
                        :for={link <- Egghead.Record.references(@selected_record)}
                        class="prop-link"
                        href={"/records/#{link}"}
                        data-phx-link="patch"
                        data-phx-link-state="push"
                      >
                        {link}
                      </a>
                    </dd>
                  </div>
                  <div :if={@backlinks != []} class="prop-row">
                    <dt>backlinks</dt>
                    <dd>
                      <a
                        :for={bl <- @backlinks}
                        class="prop-link"
                        href={"/records/#{bl.id}"}
                        data-phx-link="patch"
                        data-phx-link-state="push"
                      >
                        {bl.id}
                      </a>
                    </dd>
                  </div>
                  <%= for {key, val} <- @selected_record.meta do %>
                    <div class="prop-row">
                      <dt>{key}</dt>
                      <dd>{inspect(val)}</dd>
                    </div>
                  <% end %>
                </dl>
              </details>
              <div
                id={"editor-#{@selected_record.id}"}
                phx-hook="YjsEditor"
                phx-update="ignore"
                data-record-id={@selected_record.id}
                data-format={to_string(@selected_record.format)}
                class={"record-editor record-editor-#{@selected_record.format}"}
              >
              </div>
            </div>
            <div :if={!@selected_record} class="empty-state">
              <p>Select a record to begin.</p>
            </div>
          </main>

          <:footer :if={@selected_record}>
            <span class="status-cell">{length(@backlinks)} backlinks</span>
            <span class="status-cell">{@word_count} words</span>
            <span class="status-cell">{@selected_record.class}</span>
          </:footer>
        </.window>

        <%!-- Chat window — stable id so persisted geom survives room
             switches. The Rooms ▾ menu lists every room in the system;
             clicking a row switches the chat to it; clicking × on a
             non-default room stops the room (saves the transcript). --%>
        <% default_room = Egghead.default_room() || "default" %>
        <% all_rooms = list_chat_rooms_safe() %>
        <.window
          id="chat-window"
          title={"Chat — " <> @active_chat_room}
          role={:panel}
          default_x={864}
          default_y={8}
          default_w={280}
          default_h={720}
          default_z={2}
          open={true}
        >
          <div class="chat-irc">
            <%!-- Header strip: Rooms ▾ menu, new-room button, agents ▾.
                 Room name is intentionally absent — the window tab
                 already shows it. --%>
            <div class="chat-header">
              <div class="rooms-menu-wrap">
                <button
                  type="button"
                  class={["menu-field", @rooms_menu_open && "toggled"]}
                  phx-click="toggle_rooms_menu"
                  title="Switch or open chat rooms"
                >
                  <img src="/assets/icon-chat.png" alt="" class="menu-field-icon" />
                  <span class="menu-field-label">Rooms</span>
                  <span class="menu-field-arrow">▾</span>
                </button>
                <div :if={@rooms_menu_open} class="menu-field-dropdown" role="menu">
                  <%= for room <- all_rooms do %>
                    <% active? = room == @active_chat_room %>
                    <% droppable? = room != default_room %>
                    <div class="menu-field-row">
                      <button
                        type="button"
                        class={["menu-field-item", active? && "is-active"]}
                        phx-click="switch_chat_room"
                        phx-value-room={room}
                      >
                        <span class="menu-field-marker">
                          {if active?, do: "●", else: Phoenix.HTML.raw("&nbsp;")}
                        </span>
                        <span class="menu-field-text">{room}</span>
                      </button>
                      <button
                        :if={droppable?}
                        type="button"
                        class="menu-field-close"
                        phx-click="drop_chat_room"
                        phx-value-room={room}
                        aria-label={"Drop " <> room}
                        title="Drop this room (saves transcript)"
                      >
                        ×
                      </button>
                    </div>
                  <% end %>
                </div>
              </div>

              <%!-- New room. The hook prompts for a name and pushes
                   `switch_chat_room` (which validates + creates +
                   switches in one path). --%>
              <button
                type="button"
                id="new-room-btn"
                class="menu-field new-room-btn"
                phx-hook="NewRoomButton"
                title="Create a new chat room"
              >
                <span class="menu-field-label" aria-hidden="true">+</span>
              </button>

              <div class="toolbar-spacer"></div>

              <button
                type="button"
                class={["menu-field roster-toggle", @show_agents && "toggled"]}
                phx-click="toggle_agents"
                title="Show agent roster"
              >
                <img src="/assets/icon-agent.png" alt="" class="menu-field-icon" />
                <span class="menu-field-label">
                  {length(@agents)} {if length(@agents) == 1, do: "Agent", else: "Agents"}
                </span>
                <span class="menu-field-arrow">▾</span>
              </button>
            </div>

            <%!-- Agent roster — collapsible, IRC-style names list --%>
            <div :if={@show_agents} class="chat-roster">
              <div :if={@agents == []} class="roster-empty">No agents in room.</div>
              <div :for={agent <- @agents} class="roster-row">
                <span class={[
                  "roster-dot",
                  agent.status == :active && "active",
                  agent.status == :handoff && "handoff"
                ]}>
                  <%= case agent.status do %>
                    <% :active -> %>
                      ●
                    <% :handoff -> %>
                      ↻
                    <% _ -> %>
                      ○
                  <% end %>
                </span>
                <span class="roster-name" style={"color: #{agent_nick_color(agent.id)}"}>
                  {agent.name}
                </span>
                <span :if={agent.ctx_window > 0} class="roster-ctx">
                  {format_tokens(agent.ctx_tokens)}/{format_tokens(agent.ctx_window)}
                </span>
                <div :if={agent.ctx_window > 0} class="roster-bar" title={"#{agent.ctx_pct}% used"}>
                  <div class="roster-bar-fill" style={"width: #{min(agent.ctx_pct, 100)}%"}></div>
                </div>
              </div>
            </div>

            <%!-- Transcript: nick-prefixed lines, IRC style --%>
            <div class="chat-transcript" id="chat-transcript" phx-hook="ScrollBottom">
              <%= for {entry, show_nick?} <- collapse_nicks(@transcript) do %>
                <%= case entry.kind do %>
                  <% :agent -> %>
                    <div class="bubble-row agent-row">
                      <div class="bubble agent-bubble">
                        <div :if={show_nick?} class="bubble-header">
                          <span
                            class="bubble-name"
                            style={"color: #{agent_nick_color(entry.sender_id)}"}
                          >
                            {entry.sender_name}
                          </span>
                          <span :if={entry.timestamp} class="bubble-time">
                            {Calendar.strftime(entry.timestamp, "%H:%M")}
                          </span>
                        </div>
                        <div class="bubble-body markdown-body">
                          {Phoenix.HTML.raw(render_entry_html(entry))}
                        </div>
                      </div>
                    </div>
                  <% :user -> %>
                    <div class="bubble-row user-row">
                      <div class="bubble user-bubble">
                        <div :if={show_nick?} class="bubble-header">
                          <span class="bubble-name user-name">{entry.sender_name}</span>
                          <span :if={entry.timestamp} class="bubble-time">
                            {Calendar.strftime(entry.timestamp, "%H:%M")}
                          </span>
                        </div>
                        <div class="bubble-body markdown-body">
                          {Phoenix.HTML.raw(render_entry_html(entry))}
                        </div>
                      </div>
                    </div>
                  <% :action -> %>
                    <div class="meta-line action">
                      <span class="meta-sym">*</span>
                      <span class="meta-text">
                        <span
                          class="action-nick"
                          style={"color: #{agent_nick_color(entry.sender_id)}"}
                        >
                          {entry.sender_name}
                        </span>
                        {entry.text}
                      </span>
                    </div>
                  <% :denial -> %>
                    <div class="meta-line denial">
                      <span class="meta-sym">⚠</span>
                      <span class="meta-text">
                        <strong>{entry.sender_name}</strong>
                        <span :for={l <- String.split(entry.text, "\n")} class="denial-line">
                          {l}
                        </span>
                      </span>
                    </div>
                  <% :system -> %>
                    <div class="meta-line">
                      <span class="meta-sym">—</span>
                      <span class="meta-text">
                        {Phoenix.HTML.raw(render_entry_html(entry))}
                      </span>
                    </div>
                  <% :handoff -> %>
                    <div class="meta-line">
                      <span class="meta-sym">»</span>
                      <span class="meta-text">
                        {Phoenix.HTML.raw(render_entry_html(entry))}
                      </span>
                    </div>
                  <% _ -> %>
                    <div class="meta-line">
                      <span class="meta-text">
                        {Phoenix.HTML.raw(render_entry_html(entry))}
                      </span>
                    </div>
                <% end %>
              <% end %>

              <%!-- Typing indicators for agents with active streams --%>
              <div
                :for={{name, agent_id} <- typing_agents(@active_streams)}
                class="bubble-row agent-row"
              >
                <div class="bubble agent-bubble typing-bubble">
                  <span class="bubble-name" style={"color: #{agent_nick_color(agent_id)}"}>
                    {name}
                  </span>
                  <span class="typing-dots">{typing_indicator(@anim_frame)}</span>
                </div>
              </div>
            </div>

            <div :if={@chat_status} class="chat-status">{@chat_status}</div>

            <%!-- Paste chips. Click the chip to open a BeOS-window
                 preview with the full content. The × removes the chip
                 outright. The chip's content is appended to the
                 outgoing message on send (server-side reassembly). --%>
            <div :if={@paste_chips != []} class="paste-chips">
              <div :for={chip <- @paste_chips} class="paste-chip-wrap">
                <button
                  type="button"
                  class="paste-chip"
                  phx-click="open_paste_modal"
                  phx-value-id={chip.id}
                  title="Click to view paste contents"
                >
                  <img src="/assets/icon-clipboard.png" alt="" class="paste-icon" />
                  <span class="paste-head">{chip.head}</span>
                  <span :if={chip.extra_lines > 0} class="paste-tail">
                    +{chip.extra_lines} lines
                  </span>
                </button>
                <button
                  type="button"
                  class="paste-chip-close"
                  phx-click="remove_paste_chip"
                  phx-value-id={chip.id}
                  aria-label="Remove paste"
                  title="Remove paste"
                >
                  ×
                </button>
              </div>
            </div>

            <%!-- Completion popover is mounted/owned by the ChatInput JS
                 hook. Mirrors TUI behavior: filtering, arrow nav, Tab,
                 and Esc are entirely client-side; the server only sees
                 the final message on send. --%>

            <%!-- Input bar: ❯ prompt + textarea (single-row, grows to N) --%>
            <div class="chat-input-wrap">
              <div class="chat-drag-handle" id="chat-drag-handle" phx-hook="DragHandle"></div>
              <form
                phx-submit="send_chat"
                class="chat-input"
                id="chat-input-form"
                phx-update="ignore"
              >
                <span class="chat-prompt" aria-hidden="true">❯</span>
                <textarea
                  id="chat-textarea"
                  name="message"
                  placeholder={
                    if @room_id, do: "Type a message — / for commands, @ to mention", else: "No room"
                  }
                  autocomplete="off"
                  disabled={is_nil(@room_id)}
                  rows="1"
                  phx-hook="ChatInput"
                ></textarea>
              </form>
            </div>
          </div>
        </.window>

        <%!-- Paste preview window — a real BeOS-flavored window that
             floats over everything when a chip is clicked. Server
             owns its lifecycle via close_event. --%>
        <% active_chip =
          if @active_paste_chip,
            do: Enum.find(@paste_chips, &(&1.id == @active_paste_chip)),
            else: nil %>
        <.window
          :if={active_chip}
          id="paste-modal"
          title={"Paste #{active_chip.id}"}
          subtitle={"#{active_chip.char_count} chars · #{active_chip.extra_lines + 1} lines"}
          role={:ephemeral}
          default_x={300}
          default_y={120}
          default_w={560}
          default_h={420}
          default_z={50}
          open={true}
          class="window-paste-modal"
          close_event="close_paste_modal"
        >
          <div class="paste-modal-body">
            <pre class="paste-content">{active_chip.full_text}</pre>
          </div>
          <:footer>
            <button
              type="button"
              class="btn-chrome paste-modal-remove"
              phx-click="remove_paste_chip"
              phx-value-id={active_chip.id}
              title="Discard this paste"
            >
              Remove paste
            </button>
          </:footer>
        </.window>
      </div>
    </div>
    """
  end
end
