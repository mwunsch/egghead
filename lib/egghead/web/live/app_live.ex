defmodule Egghead.Web.AppLive do
  use Egghead.Web, :live_view

  alias Egghead.Web.MarkdownHTML
  alias Egghead.TUI.Records.Slug

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Egghead.PubSub, Egghead.RecordStore.records_topic())
    end

    all = Egghead.list_records() |> Enum.sort_by(&(&1.updated || ""), :desc)

    selected_id =
      case params["id"] do
        nil -> nil
        segments when is_list(segments) -> Enum.join(segments, "/")
        id when is_binary(id) -> id
      end

    room_id = Egghead.default_room()

    socket =
      socket
      |> assign(
        # Layout state
        nav_open: true,
        chat_open: true,
        # Nav state
        query: "",
        all: all,
        filtered: all,
        class_filter: MapSet.new([:durable, :inbox, :deliberation, :agent]),
        class_dropdown_open: false,
        nav_view: :search,
        tree_open: MapSet.new(),
        # Record state
        selected_id: selected_id,
        selected_record: nil,
        selected_body_html: nil,
        backlinks: [],
        word_count: 0,
        # Chat state
        room_id: room_id,
        transcript: [],
        active_streams: %{},
        chat_status: nil,
        chat_input: "",
        chat_dropdown: nil,
        paste_chips: [],
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
    id =
      case params["id"] do
        nil -> nil
        segments when is_list(segments) -> Enum.join(segments, "/")
        id when is_binary(id) -> id
      end

    if id do
      {:noreply, socket |> assign(selected_id: id) |> hydrate_selection()}
    else
      {:noreply,
       assign(socket,
         selected_id: nil,
         selected_record: nil,
         selected_body_html: nil,
         backlinks: [],
         word_count: 0
       )}
    end
  end

  # --- UI events ---

  @impl true
  def handle_event("toggle_nav", _, socket) do
    {:noreply, assign(socket, nav_open: !socket.assigns.nav_open)}
  end

  def handle_event("toggle_chat", _, socket) do
    {:noreply, assign(socket, chat_open: !socket.assigns.chat_open)}
  end

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
     |> assign(class_filter: MapSet.new([:durable, :inbox, :deliberation, :agent]))
     |> apply_filter()}
  end

  def handle_event("class_select_none", _, socket) do
    {:noreply, socket |> assign(class_filter: MapSet.new()) |> apply_filter()}
  end

  def handle_event("switch_nav_view", %{"view" => view}, socket) do
    {:noreply, assign(socket, nav_view: String.to_existing_atom(view))}
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
    # Expand any paste chips back to full text
    message =
      Enum.reduce(socket.assigns.paste_chips, message, fn chip, msg ->
        String.replace(msg, chip.placeholder, chip.full_text)
      end)
      |> String.trim()

    socket = assign(socket, chat_input: "", chat_dropdown: nil, paste_chips: [])

    cond do
      message == "" ->
        {:noreply, socket}

      String.starts_with?(message, "/") ->
        {:noreply, dispatch_slash_command(message, socket)}

      socket.assigns.room_id ->
        Egghead.chat(socket.assigns.room_id, message)
        {:noreply, socket}

      true ->
        {:noreply, assign(socket, chat_status: "No chat room available.")}
    end
  end

  def handle_event("chat_input_change", %{"value" => value}, socket) do
    {:noreply, socket |> assign(chat_input: value) |> detect_completion(value)}
  end

  def handle_event("chat_dropdown_up", _, socket) do
    {:noreply, move_dropdown(socket, -1)}
  end

  def handle_event("chat_dropdown_down", _, socket) do
    {:noreply, move_dropdown(socket, 1)}
  end

  def handle_event("chat_tab_complete", _, socket) do
    {:noreply, accept_completion(socket)}
  end

  def handle_event("chat_escape", _, socket) do
    {:noreply, assign(socket, chat_dropdown: nil)}
  end

  def handle_event("chat_paste", %{"text" => text}, socket) do
    chip = build_paste_chip(text, socket.assigns.paste_chips)
    chips = socket.assigns.paste_chips ++ [chip]
    # The placeholder gets inserted into the textarea via the current input
    {:noreply,
     assign(socket, paste_chips: chips, chat_input: socket.assigns.chat_input <> chip.placeholder)}
  end

  def handle_event("toggle_agents", _, socket) do
    {:noreply, assign(socket, show_agents: !socket.assigns.show_agents)}
  end

  def handle_event("select_dropdown", %{"index" => idx}, socket) do
    case socket.assigns.chat_dropdown do
      %{candidates: cands} = dd when is_list(cands) ->
        i = String.to_integer(idx)
        {:noreply, assign(socket, chat_dropdown: %{dd | selected: i}) |> accept_completion()}

      _ ->
        {:noreply, socket}
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

    {:noreply, socket}
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
      |> drop_stream(msg.sender.id)
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

  def handle_info({:agents_activated, _count}, socket), do: {:noreply, socket}

  def handle_info({:agent_passed, agent_id}, socket) do
    {:noreply, drop_stream(socket, agent_id)}
  end

  def handle_info(:budget_exhausted, socket) do
    {:noreply,
     assign(socket, chat_status: "Budget exhausted \u2014 type /continue to grant more turns.")}
  end

  def handle_info(:continued, socket) do
    {:noreply, assign(socket, chat_status: nil)}
  end

  def handle_info({:agent_joined, agent_id}, socket) do
    entry = Egghead.TUI.Chat.Entry.system("#{agent_display_name(agent_id)} joined")
    {:noreply, append_entry(socket, entry)}
  end

  def handle_info({:agent_left, agent_id}, socket) do
    entry = Egghead.TUI.Chat.Entry.system("#{agent_display_name(agent_id)} left")
    {:noreply, append_entry(socket, entry)}
  end

  def handle_info({:agent_handoff, _room_id, agent_id, _delib_id}, socket) do
    entry = Egghead.TUI.Chat.Entry.system("#{agent_display_name(agent_id)} handed off context")
    {:noreply, append_entry(socket, entry)}
  end

  def handle_info({:agent_mentions, _room_id, _from, _to}, socket), do: {:noreply, socket}

  def handle_info({:system_notice, text}, socket) do
    {:noreply, append_entry(socket, Egghead.TUI.Chat.Entry.system(text))}
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
            html =
              MarkdownHTML.render(record.body || "",
                link_fn: &"/records/#{&1}",
                exists_fn: &record_exists?/1
              )

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

  defp hydrate_chat(socket) do
    case socket.assigns.room_id do
      nil ->
        socket

      room_id ->
        if connected?(socket) do
          Egghead.Chat.Room.subscribe(room_id)
        end

        transcript =
          case Egghead.Chat.Room.get_transcript(room_id) do
            {:ok, messages} ->
              Enum.map(messages, fn msg ->
                case msg.sender.type do
                  :user ->
                    Egghead.TUI.Chat.Entry.user(msg.sender.name, msg.content)

                  :agent ->
                    Egghead.TUI.Chat.Entry.agent(
                      msg.sender.id,
                      msg.sender.name,
                      msg.content
                    )
                end
              end)

            _ ->
              []
          end

        agents =
          try do
            Egghead.list_agents()
            |> Enum.map(
              &%{
                id: &1.id,
                name: &1.name,
                status: :idle,
                ctx_pct: 0.0,
                ctx_window: 0,
                session_tokens: 0
              }
            )
          catch
            _, _ -> []
          end

        assign(socket, transcript: transcript, agents: agents)
    end
  end

  # Buffer streaming deltas and commit on \n\n (paragraph break).
  # Each committed paragraph becomes its own chat bubble.
  # Single \n within a paragraph renders as a line break inside the bubble.
  defp apply_stream_delta(socket, agent_id, delta) do
    current = socket.assigns.active_streams
    name = agent_display_name(agent_id)

    buf =
      case Map.get(current, agent_id) do
        nil ->
          %{
            agent_id: agent_id,
            name: name,
            text: "",
            started_at: System.monotonic_time(:millisecond)
          }

        existing ->
          existing
      end

    new_text = buf.text <> delta

    case String.split(new_text, "\n\n") do
      [single] ->
        # No paragraph break yet — just buffer
        buf = %{buf | text: single}

        socket
        |> assign(active_streams: Map.put(current, agent_id, buf))

      parts ->
        # Last element is the trailing incomplete paragraph
        {commits, [tail]} = Enum.split(parts, -1)

        entries =
          commits
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&Egghead.TUI.Chat.Entry.agent(agent_id, name, String.trim(&1)))

        buf = %{buf | text: tail}

        socket
        |> assign(active_streams: Map.put(current, agent_id, buf))
        |> append_entries(entries)
    end
  end

  defp finalize_stream(socket, agent_id) do
    case Map.get(socket.assigns.active_streams, agent_id) do
      nil ->
        socket

      buf ->
        text = String.trim(buf.text)

        if text == "" do
          socket
        else
          append_entry(socket, Egghead.TUI.Chat.Entry.agent(agent_id, buf.name, text))
        end
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
    |> Enum.filter(fn {_id, s} -> s.text != "" end)
    |> Enum.sort_by(fn {_id, s} -> s.started_at end)
    |> Enum.map(fn {_id, s} -> {s.name, s.agent_id} end)
  end

  defp render_entry_html(%Egghead.TUI.Chat.Entry{text: text}) do
    MarkdownHTML.render(text)
  end

  # --- Slash commands ---

  @chat_commands %{
    "save" => :cmd_save,
    "continue" => :cmd_continue,
    "handoff" => :cmd_handoff,
    "help" => :cmd_help
  }

  @chat_command_list [
    %{name: "save", description: "Save transcript as a record"},
    %{name: "continue", description: "Grant agents more turns"},
    %{name: "handoff", description: "Handoff an agent's context"},
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
          case Egghead.chat_save(socket.assigns.room_id) do
            {:ok, record_id} ->
              append_entry(
                socket,
                Egghead.TUI.Chat.Entry.system("Transcript saved \u2192 [[#{record_id}]]")
              )

            _ ->
              append_entry(socket, Egghead.TUI.Chat.Entry.system("Save failed"))
          end
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

        if target == "" do
          append_entry(socket, Egghead.TUI.Chat.Entry.system("Usage: /handoff <agent>"))
        else
          if socket.assigns.room_id do
            try do
              Egghead.handoff(target)
            catch
              _, _ -> :ok
            end

            append_entry(socket, Egghead.TUI.Chat.Entry.system("Handoff initiated for #{target}"))
          else
            socket
          end
        end

      :cmd_help ->
        socket
        |> append_entry(
          Egghead.TUI.Chat.Entry.system("Commands: /save /continue /handoff <agent> /help")
        )
        |> append_entry(
          Egghead.TUI.Chat.Entry.system(
            "Enter send | Shift+Enter newline | @agent mention | \\[\\[record\\]\\] link"
          )
        )
    end
  end

  # --- Completion detection ---

  defp detect_completion(socket, value) do
    cond do
      # Slash commands
      String.starts_with?(value, "/") and not String.contains?(value, "\n") ->
        prefix = value |> String.trim_leading("/") |> String.downcase()

        candidates =
          @chat_command_list
          |> Enum.filter(&String.starts_with?(&1.name, prefix))

        assign(socket,
          chat_dropdown: %{kind: :command, prefix: prefix, candidates: candidates, selected: 0}
        )

      # @agent mention
      String.match?(value, ~r/(^|\s)@([a-zA-Z0-9\/_\-]*)$/) ->
        [_, _, prefix] = Regex.run(~r/(^|\s)@([a-zA-Z0-9\/_\-]*)$/, value)

        agents =
          try do
            Egghead.list_agents()
          catch
            _, _ -> []
          end

        candidates =
          agents
          |> Enum.filter(fn a ->
            basename = a.id |> String.split("/") |> List.last() |> String.downcase()
            String.starts_with?(basename, String.downcase(prefix))
          end)
          |> Enum.take(8)
          |> Enum.map(&%{id: &1.id, name: &1.name})

        if candidates != [] do
          ghost =
            case Enum.at(candidates, 0) do
              %{id: id} ->
                basename = id |> String.split("/") |> List.last()

                if String.starts_with?(String.downcase(basename), String.downcase(prefix)),
                  do: String.slice(basename, String.length(prefix)..-1//1),
                  else: ""

              _ ->
                ""
            end

          assign(socket,
            chat_dropdown: %{
              kind: :agent,
              prefix: prefix,
              candidates: candidates,
              selected: 0,
              ghost: ghost
            }
          )
        else
          assign(socket, chat_dropdown: nil)
        end

      # [[record]] wikilink
      String.match?(value, ~r/\[\[([a-zA-Z0-9\/_\-]*)$/) ->
        [_, prefix] = Regex.run(~r/\[\[([a-zA-Z0-9\/_\-]*)$/, value)

        candidates =
          Egghead.recent(limit: 50)
          |> Enum.filter(fn r ->
            String.starts_with?(String.downcase(r.id || ""), String.downcase(prefix))
          end)
          |> Enum.take(8)
          |> Enum.map(&%{id: &1.id, title: &1.title})

        if candidates != [] do
          assign(socket,
            chat_dropdown: %{
              kind: :record,
              prefix: prefix,
              candidates: candidates,
              selected: 0,
              ghost: ""
            }
          )
        else
          assign(socket, chat_dropdown: nil)
        end

      true ->
        assign(socket, chat_dropdown: nil)
    end
  end

  defp move_dropdown(socket, dir) do
    case socket.assigns.chat_dropdown do
      %{candidates: cands, selected: sel} = dd when cands != [] ->
        n = length(cands)
        new_sel = rem(sel + dir + n, n)
        assign(socket, chat_dropdown: %{dd | selected: new_sel})

      _ ->
        socket
    end
  end

  defp accept_completion(socket) do
    new_value =
      case socket.assigns.chat_dropdown do
        %{kind: :command, candidates: [_ | _] = cands, selected: sel} ->
          "/#{Enum.at(cands, sel).name} "

        %{kind: :agent, candidates: [_ | _] = cands, selected: sel} ->
          Regex.replace(
            ~r/@[a-zA-Z0-9\/_\-]*$/,
            socket.assigns.chat_input,
            "@#{Enum.at(cands, sel).id} "
          )

        %{kind: :record, candidates: [_ | _] = cands, selected: sel} ->
          Regex.replace(
            ~r/\[\[[a-zA-Z0-9\/_\-]*$/,
            socket.assigns.chat_input,
            "[[#{Enum.at(cands, sel).id}]] "
          )

        _ ->
          nil
      end

    if new_value do
      socket
      |> assign(chat_input: new_value, chat_dropdown: nil)
      |> push_event("update_input", %{value: new_value})
    else
      socket
    end
  end

  # --- Paste chips ---

  defp build_paste_chip(text, existing) do
    id = length(existing) + 1
    lines = text |> String.split("\n") |> length()

    first_line =
      text |> String.split("\n") |> Enum.find("", &(String.trim(&1) != "")) |> String.trim()

    head =
      if String.length(first_line) > 25 do
        String.slice(first_line, 0, 25) <> "\u2026"
      else
        first_line
      end

    extra = lines - 1
    placeholder = "\u{1F4CB}[paste-#{id}]"

    %{
      id: id,
      head: head,
      extra_lines: extra,
      full_text: text,
      placeholder: placeholder
    }
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
      %{context_window: cw, session_tokens: st} when is_integer(cw) and cw > 0 ->
        pct = Float.round(st / cw * 100, 1)

        agents =
          Enum.map(socket.assigns.agents, fn
            %{id: ^agent_id} = a ->
              %{a | ctx_pct: pct, ctx_window: cw, session_tokens: st}

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

    assigns =
      assigns
      |> assign(:phantom, phantom)
      |> assign(:file_tree, file_tree)

    ~H"""
    <div class="app-shell">
      <header class="app-header">
        <div class="header-center">
          <span class="app-title">egghead</span>
          <span :if={@selected_record} class="breadcrumb">&mdash; {@selected_record.id}</span>
        </div>
      </header>
      <div class="app-toolbar">
        <button
          class={["toolbar-icon-btn", @nav_open && "depressed"]}
          phx-click="toggle_nav"
          title="Toggle records"
        >
          <img src="/assets/icon-search.png" alt="Records" class="toolbar-app-icon" />
        </button>
        <span :if={@selected_record} class="toolbar-title">
          {@selected_record.title || @selected_record.id}
        </span>
        <div class="toolbar-spacer"></div>
        <button
          class={["toolbar-icon-btn", @chat_open && "depressed"]}
          phx-click="toggle_chat"
          title="Toggle chat"
        >
          <img src="/assets/icon-chat.png" alt="Chat" class="toolbar-app-icon" />
        </button>
      </div>

      <div class="app-body">
        <%!-- Left nav sidebar --%>
        <aside class={["nav-sidebar", !@nav_open && "collapsed"]}>
          <div class="nav-inner">
            <div class="nav-toolbar">
              <button
                class={["toolbar-btn", @nav_view == :tree && "toggled"]}
                phx-click="switch_nav_view"
                phx-value-view={if @nav_view == :tree, do: "search", else: "tree"}
              >
                <img src="/assets/icon-tree.png" alt="Tree" class="toolbar-icon" />
                <span class="toolbar-label">Tree</span>
              </button>
              <div class="toolbar-spacer"></div>
              <div class="class-filter-wrap">
                <button
                  class="toolbar-btn"
                  phx-click="toggle_class_dropdown"
                >
                  <img src="/assets/icon-filter.png" alt="Filter" class="toolbar-icon" />
                  <span class="toolbar-label">Filter</span>
                </button>
                <div :if={@class_dropdown_open} class="class-dropdown">
                  <div class="dropdown-actions">
                    <button class="dropdown-link" phx-click="class_select_all">All</button>
                    <button class="dropdown-link" phx-click="class_select_none">None</button>
                  </div>
                  <label :for={c <- [:durable, :agent, :deliberation, :inbox]} class="class-option">
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
                  <span class="record-meta">{record.class}</span>
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
        </aside>

        <%!-- Center: record body --%>
        <main class="record-pane">
          <div :if={@selected_record} class="record-content">
            <details class="properties-block" open>
              <summary class="properties-summary">
                <span class="properties-summary-label">Properties</span>
                <button
                  class="btn-chrome btn-copy"
                  id="copy-md-btn"
                  phx-hook="CopyMarkdown"
                  data-markdown={@selected_record.body || ""}
                >
                  <svg
                    width="14"
                    height="14"
                    viewBox="0 0 16 16"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.5"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                  >
                    <rect x="5" y="5" width="9" height="9" rx="1" />
                    <path d="M3 11V3a1 1 0 0 1 1-1h8" />
                  </svg>
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
                <div :if={@selected_record.links != []} class="prop-row">
                  <dt>links</dt>
                  <dd>
                    <a
                      :for={link <- @selected_record.links}
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
            <article class="record-body markdown-body">
              {Phoenix.HTML.raw(@selected_body_html)}
            </article>
          </div>
          <div :if={!@selected_record} class="empty-state">
            <p>Select a record to begin.</p>
          </div>
        </main>

        <%!-- Status bar --%>
        <div :if={@selected_record} class="record-status-bar">
          <span class="status-cell">{length(@backlinks)} backlinks</span>
          <span class="status-cell">{@word_count} words</span>
          <span class="status-cell">{@selected_record.class}</span>
        </div>

        <%!-- Right: chat sidebar --%>
        <aside class={["chat-sidebar", !@chat_open && "collapsed"]}>
          <div class="chat-inner">
            <div class="chat-header">
              <span class="chat-title">Chat</span>
              <button class="toolbar-btn" phx-click="toggle_agents" title="Agent roster">
                <span class="toolbar-label">{length(@agents)} agents</span>
              </button>
            </div>

            <%!-- Agent roster panel --%>
            <div :if={@show_agents} class="agent-roster">
              <div :for={agent <- @agents} class="agent-card-wrap">
                <div class="agent-card">
                  <span class={["agent-status-dot", agent.status == :active && "active"]}>
                    {if agent.status == :active, do: "\u25CF", else: "\u25CB"}
                  </span>
                  <span class="agent-name">{agent.name}</span>
                  <span :if={agent.ctx_window > 0} class="agent-ctx">
                    {format_tokens(agent.session_tokens)}/{format_tokens(agent.ctx_window)}
                  </span>
                </div>
                <div :if={agent.ctx_window > 0} class="agent-bar">
                  <div class="agent-bar-track">
                    <div class="agent-bar-fill" style={"width: #{min(agent.ctx_pct, 100)}%"}></div>
                  </div>
                  <span class="agent-bar-label">
                    {:erlang.float_to_binary(agent.ctx_pct, decimals: 1)}%
                  </span>
                </div>
              </div>
            </div>

            <div class="chat-transcript" id="chat-transcript" phx-hook="ScrollBottom">
              <%= for {entry, show_nick?} <- collapse_nicks(@transcript) do %>
                <%= case entry.kind do %>
                  <% :agent -> %>
                    <div class="bubble-row agent-row">
                      <div class="bubble agent-bubble">
                        <div class="bubble-header">
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
                        <div class="bubble-header">
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
                      <span class="meta-text">{entry.sender_name} {entry.text}</span>
                    </div>
                  <% :denial -> %>
                    <div class="meta-line denial">
                      <span class="meta-sym">&#9888;</span>
                      <span class="meta-text">
                        <strong>{entry.sender_name}</strong>
                        <span :for={line <- String.split(entry.text, "\n")} class="denial-line">
                          {line}
                        </span>
                      </span>
                    </div>
                  <% :system -> %>
                    <div class="meta-line">
                      <span class="meta-sym">&mdash;</span>
                      <span class="meta-text">{Phoenix.HTML.raw(render_entry_html(entry))}</span>
                    </div>
                  <% :handoff -> %>
                    <div class="meta-line">
                      <span class="meta-sym">&raquo;</span>
                      <span class="meta-text">{Phoenix.HTML.raw(render_entry_html(entry))}</span>
                    </div>
                  <% _ -> %>
                    <div class="meta-line">
                      <span class="meta-text">{Phoenix.HTML.raw(render_entry_html(entry))}</span>
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

            <%!-- Dropdown (commands / mentions) --%>
            <div :if={@chat_dropdown && @chat_dropdown.candidates != []} class="chat-dropdown">
              <div
                :for={{cand, idx} <- Enum.with_index(@chat_dropdown.candidates)}
                class={["dropdown-item", idx == @chat_dropdown.selected && "selected"]}
                phx-click="select_dropdown"
                phx-value-index={idx}
              >
                <%= case @chat_dropdown.kind do %>
                  <% :command -> %>
                    <span class="dd-name">/{cand.name}</span>
                    <span class="dd-desc">{cand.description}</span>
                  <% :agent -> %>
                    <span class="dd-name">@{cand.id}</span>
                    <span class="dd-desc">{cand.name}</span>
                  <% :record -> %>
                    <span class="dd-name">[[{cand.id}]]</span>
                    <span class="dd-desc">{cand.title}</span>
                <% end %>
              </div>
            </div>

            <%!-- Paste chip display --%>
            <div :if={@paste_chips != []} class="paste-chips">
              <div :for={chip <- @paste_chips} class="paste-chip">
                <span class="paste-icon">📋</span>
                <span class="paste-head">{chip.head}</span>
                <span :if={chip.extra_lines > 0} class="paste-tail">+{chip.extra_lines} lines</span>
              </div>
            </div>

            <div class="chat-input-wrap">
              <div class="chat-drag-handle" id="chat-drag-handle" phx-hook="DragHandle"></div>
              <form phx-submit="send_chat" class="chat-input" id="chat-input-form" phx-update="ignore">
                <textarea
                  id="chat-textarea"
                  name="message"
                  placeholder={if @room_id, do: "Type a message...", else: "No room"}
                  autocomplete="off"
                  disabled={is_nil(@room_id)}
                  rows="2"
                  phx-hook="ChatInput"
                ></textarea>
              </form>
            </div>
          </div>
        </aside>
      </div>
    </div>
    """
  end
end
