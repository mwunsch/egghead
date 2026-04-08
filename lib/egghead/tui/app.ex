defmodule Egghead.TUI.App do
  @moduledoc """
  Root TermUI component for Egghead. Elm Architecture.
  """

  use TermUI.Elm

  alias TermUI.Event
  alias Egghead.TUI.State
  alias Egghead.TUI.Theme

  @impl true
  def init(_opts) do
    # Disable mouse tracking — Kitty sends escape sequences that
    # the parser can't handle, causing garbage input.
    # Get terminal size. Both calls may fail in headless/test mode.
    {w, h} =
      try do
        TermUI.Terminal.disable_mouse_tracking()

        case TermUI.Terminal.get_terminal_size() do
          {:ok, {rows, cols}} -> {cols, rows}
          _ -> {80, 24}
        end
      catch
        _, _ -> {80, 24}
      end

    all_records =
      try do
        Egghead.list_records()
      catch
        _, _ -> []
      end

    agents =
      try do
        Egghead.list_agents()
      catch
        _, _ -> []
      end

    # Check for restore state (set when returning from $EDITOR)
    restore = Application.get_env(:egghead, :tui_restore)
    Application.delete_env(:egghead, :tui_restore)

    # When returning from $EDITOR:
    # 1. Drain stale terminal responses (DECRPM, DA1, Kitty) from stdin.
    #    TermUI's Terminal.disable_raw_mode sends \ec (Full Terminal Reset).
    #    Modern terminals respond with capability announcements. OTP 28's
    #    prim_tty reads these into the Erlang IO system — they can only be
    #    consumed via IO.getn, not a raw fd read.
    # 2. Clear the BufferManager's previous buffer. The BufferManager survives
    #    across Runtime restarts (named process). Its "previous" buffer has
    #    content from before the editor, but the actual alternate screen is
    #    blank (we left and re-entered it). Without clearing, the diff
    #    computes minimal changes against stale content → blank screen.
    if restore do
      drain_stale_input()

      try do
        prev = TermUI.Renderer.BufferManager.get_previous_buffer()
        TermUI.Renderer.Buffer.clear(prev)
      catch
        _, _ -> :ok
      end
    end

    {show_all, query, selected, scroll} =
      case restore do
        %{show_all: sa, query: q, selected: s, scroll: sc} -> {sa, q, s, sc}
        _ -> {false, "", 0, 0}
      end

    results = filter_and_sort(all_records, show_all, query)
    selected = min(selected, max(0, length(results) - 1))

    base = %State{
      width: w,
      height: h,
      all_records: all_records,
      results: results,
      agents: agents,
      query: query,
      selected: selected,
      scroll_offset: scroll,
      show_all_classes: show_all
    }

    set_preview(base, preview_for_selection(base, selected))
  end

  # --- handle_info for PubSub and async messages ---

  def handle_info({:terminal_resize, {rows, cols}}, state) do
    {%{state | width: cols, height: rows}, []}
  end

  # PubSub events from the chat room arrive here when in chat mode.
  # Each clause translates the event into an :update_loop message via
  # update/2 so all state changes flow through the Elm update function.
  def handle_info({:user_message, msg}, %{mode: :chat} = state),
    do: update({:room_event, {:user_message, msg}}, state)

  def handle_info({:agent_message, msg}, %{mode: :chat} = state),
    do: update({:room_event, {:agent_message, msg}}, state)

  def handle_info({:agent_streaming, _room_id, agent_id, delta}, %{mode: :chat} = state),
    do: update({:room_event, {:agent_streaming, agent_id, delta}}, state)

  def handle_info(
        {:agent_tool_call, _room_id, agent_id, tool_name, input},
        %{mode: :chat} = state
      ),
      do: update({:room_event, {:agent_tool_call, agent_id, tool_name, input}}, state)

  def handle_info({:agents_activated, count}, %{mode: :chat} = state),
    do: update({:room_event, {:agents_activated, count}}, state)

  def handle_info({:agent_passed, agent_id}, %{mode: :chat} = state),
    do: update({:room_event, {:agent_passed, agent_id}}, state)

  def handle_info({:agent_joined, agent_id}, %{mode: :chat} = state),
    do: update({:room_event, {:agent_joined, agent_id}}, state)

  def handle_info({:agent_left, agent_id}, %{mode: :chat} = state),
    do: update({:room_event, {:agent_left, agent_id}}, state)

  def handle_info({:agent_handoff, _room_id, agent_id, delib_id}, %{mode: :chat} = state),
    do: update({:room_event, {:agent_handoff, agent_id, delib_id}}, state)

  def handle_info(:budget_exhausted, %{mode: :chat} = state),
    do: update({:room_event, :budget_exhausted}, state)

  def handle_info(:continued, %{mode: :chat} = state),
    do: update({:room_event, :continued}, state)

  # Ignored coordinator signal — agents @-mentioning each other is internal
  def handle_info({:agent_mentions, _, _, _}, %{mode: :chat} = state), do: {state, []}

  # Animation tick for the thinking-ellipsis. Increments the frame
  # counter (state change → re-render) and reschedules another tick if
  # any agent stream is still active. The %{mode: :chat} guard means
  # ticks that arrive after leaving chat mode are no-ops.
  def handle_info(:chat_anim_tick, %{mode: :chat} = state) do
    state = %{
      state
      | chat_anim_frame: state.chat_anim_frame + 1,
        chat_anim_pending: false
    }

    state =
      if map_size(state.chat_streams) > 0 do
        schedule_chat_anim_tick(state)
      else
        state
      end

    {state, []}
  end

  def handle_info(:chat_anim_tick, state), do: {%{state | chat_anim_pending: false}, []}

  # Catch-all: required to return {state, []} (NOT just state) — TermUI
  # expects a tuple from handle_info or it crashes the runtime.
  def handle_info(_msg, state), do: {state, []}

  # --- Event handling ---

  @impl true
  # Ctrl+Q as in-app quit
  def event_to_msg(%Event.Key{key: "q", modifiers: [:ctrl]}, _state), do: {:msg, :quit}

  def event_to_msg(%Event.Key{key: :escape}, %{command_mode: true}) do
    {:msg, :exit_command}
  end

  # Ctrl+G exits command mode (Emacs convention)
  def event_to_msg(%Event.Key{key: "g", modifiers: [:ctrl]}, %{command_mode: true}) do
    {:msg, :exit_command}
  end

  def event_to_msg(%Event.Key{} = event, %{command_mode: true} = state) do
    command_event(event, state)
  end

  def event_to_msg(%Event.Key{} = event, %{mode: :records} = state) do
    records_event(event, state)
  end

  def event_to_msg(%Event.Key{} = event, %{mode: :chat} = state) do
    chat_event(event, state)
  end

  def event_to_msg(%Event.Resize{width: w, height: h}, _state) do
    {:msg, {:resize, w, h}}
  end

  def event_to_msg(_event, _state), do: :ignore

  # --- Update ---

  @impl true
  def update(msg, state) do
    case msg do
      :quit ->
        # Belt-and-suspenders: call shutdown directly in case [:quit]
        # command processing fails (e.g. second Runtime after editor)
        TermUI.Runtime.shutdown(self())
        {state, [:quit]}

      {:resize, w, h} ->
        {%{state | width: w, height: h}, []}

      # Search
      {:char, c} ->
        query = state.query <> c
        search(state, query)

      :backspace ->
        query = String.slice(state.query, 0..-2//1)
        search(state, query)

      # Navigation
      :move_up ->
        new_sel = max(0, state.selected - 1)
        scroll = adjust_scroll(new_sel, state.scroll_offset, list_height(state))
        new_state = %{state | selected: new_sel, scroll_offset: scroll}

        {set_preview(new_state, preview_for_selection(new_state, new_sel)), []}

      :move_down ->
        max_sel = max(0, list_total(state) - 1)
        new_sel = min(max_sel, state.selected + 1)
        scroll = adjust_scroll(new_sel, state.scroll_offset, list_height(state))
        new_state = %{state | selected: new_sel, scroll_offset: scroll}

        {set_preview(new_state, preview_for_selection(new_state, new_sel)), []}

      :preview_scroll_down ->
        max_scroll = compute_max_scroll(state)
        new_scroll = min(state.preview_scroll + 5, max_scroll)
        {%{state | preview_scroll: new_scroll}, []}

      :preview_scroll_up ->
        {%{state | preview_scroll: max(0, state.preview_scroll - 5)}, []}

      :toggle_filter ->
        show_all = not state.show_all_classes
        results = filter_and_sort(state.all_records, show_all, state.query)

        new_state = %{
          state
          | show_all_classes: show_all,
            results: results,
            selected: 0,
            scroll_offset: 0
        }

        {set_preview(new_state, preview_for_selection(new_state, 0)), []}

      :toggle_date_format ->
        new_format = if state.date_format == :relative, do: :iso, else: :relative
        {%{state | date_format: new_format}, []}

      :open_editor ->
        if state.selected == phantom_index(state) do
          {title, slug} = creation_target(state)
          create_and_open(state, slug, title)
        else
          open_in_editor(state)
        end

      # Link navigation
      :link_next ->
        case state.preview_links do
          [] ->
            {state, []}

          links ->
            idx =
              case state.link_index do
                nil -> 0
                i -> rem(i + 1, length(links))
              end

            new_state = %{state | link_index: idx}
            {scroll_to_link(new_state), []}
        end

      :link_deselect ->
        {%{state | link_index: nil}, []}

      :follow_link ->
        case Enum.at(state.preview_links, state.link_index || -1) do
          {target_id, _, _} ->
            case Egghead.get_record(target_id) do
              {:ok, record} ->
                history =
                  if state.preview,
                    do: [state.preview.id | state.nav_history],
                    else: state.nav_history

                {set_preview(%{state | nav_history: history}, record), []}

              _ ->
                {state, []}
            end

          nil ->
            {state, []}
        end

      :nav_back ->
        case state.nav_history do
          [prev_id | rest] ->
            case Egghead.get_record(prev_id) do
              {:ok, record} ->
                {set_preview(%{state | nav_history: rest}, record), []}

              _ ->
                {%{state | nav_history: rest}, []}
            end

          [] ->
            {state, []}
        end

      # Command mode
      :enter_command ->
        {%{state | command_mode: true, command_input: "", command_selected: 0}, []}

      :exit_command ->
        {%{state | command_mode: false, command_input: ""}, []}

      {:command_char, c} ->
        {%{state | command_input: state.command_input <> c, command_selected: 0}, []}

      :command_backspace ->
        if state.command_input == "" do
          # Backspace on empty input exits command mode (deletes the /)
          {%{state | command_mode: false}, []}
        else
          input = String.slice(state.command_input, 0..-2//1)
          {%{state | command_input: input, command_selected: 0}, []}
        end

      :command_up ->
        {%{state | command_selected: max(0, state.command_selected - 1)}, []}

      :command_down ->
        cmds = filtered_commands(state.command_input, state.mode)
        max_i = max(0, length(cmds) - 1)
        {%{state | command_selected: min(max_i, state.command_selected + 1)}, []}

      :command_execute ->
        execute_command(state)

      # PubSub events from the chat room (dispatched via handle_info clauses)
      {:room_event, event} ->
        {handle_room_event(event, state), []}

      # --- Chat mode input handling ---
      {:chat_char, c} ->
        {before, rest} = String.split_at(state.chat_input, state.chat_cursor)
        new_input = before <> c <> rest
        new_cursor = state.chat_cursor + String.length(c)

        {refresh_chat_ghost(%{state | chat_input: new_input, chat_cursor: new_cursor}), []}

      :chat_backspace ->
        cond do
          state.chat_cursor > 0 ->
            {before, rest} = String.split_at(state.chat_input, state.chat_cursor)
            new_before = String.slice(before, 0, String.length(before) - 1)
            new_input = new_before <> rest
            new_cursor = state.chat_cursor - 1

            {refresh_chat_ghost(%{state | chat_input: new_input, chat_cursor: new_cursor}), []}

          state.chat_input == "" and state.chat_input_extra_lines != [] ->
            extras = state.chat_input_extra_lines
            last = List.last(extras)
            new_extras = Enum.drop(extras, -1)

            {refresh_chat_ghost(%{
               state
               | chat_input_extra_lines: new_extras,
                 chat_input: last,
                 chat_cursor: String.length(last)
             }), []}

          true ->
            {state, []}
        end

      :chat_delete ->
        # Forward delete (Ctrl+D when buffer non-empty)
        if state.chat_cursor < String.length(state.chat_input) do
          {before, rest} = String.split_at(state.chat_input, state.chat_cursor)
          new_rest = String.slice(rest, 1, String.length(rest))
          {refresh_chat_ghost(%{state | chat_input: before <> new_rest}), []}
        else
          {state, []}
        end

      :chat_cursor_left ->
        {%{state | chat_cursor: max(0, state.chat_cursor - 1)}, []}

      :chat_cursor_right ->
        {%{state | chat_cursor: min(String.length(state.chat_input), state.chat_cursor + 1)}, []}

      :chat_cursor_home ->
        {%{state | chat_cursor: 0}, []}

      :chat_cursor_end ->
        {%{state | chat_cursor: String.length(state.chat_input)}, []}

      :chat_kill_line ->
        # Ctrl+K — delete from cursor to end of line
        {before, _rest} = String.split_at(state.chat_input, state.chat_cursor)
        {refresh_chat_ghost(%{state | chat_input: before}), []}

      :chat_kill_to_start ->
        # Ctrl+U — delete from start of line to cursor
        {_before, rest} = String.split_at(state.chat_input, state.chat_cursor)
        {refresh_chat_ghost(%{state | chat_input: rest, chat_cursor: 0}), []}

      :chat_kill_word ->
        # Ctrl+W — delete previous word
        {before, rest} = String.split_at(state.chat_input, state.chat_cursor)

        new_before =
          before
          |> String.reverse()
          |> String.replace(~r/^\s*\S+/, "")
          |> String.reverse()

        {refresh_chat_ghost(%{
           state
           | chat_input: new_before <> rest,
             chat_cursor: String.length(new_before)
         }), []}

      :chat_newline ->
        new_extras = state.chat_input_extra_lines ++ [state.chat_input]
        {%{state | chat_input_extra_lines: new_extras, chat_input: "", chat_cursor: 0, chat_ghost: nil}, []}

      :chat_send ->
        chat_send(state)

      :chat_leave ->
        leave_chat_mode(state)

      :chat_accept_ghost ->
        case state.chat_ghost do
          ghost when is_binary(ghost) and ghost != "" ->
            new_input = state.chat_input <> ghost

            {refresh_chat_ghost(%{
               state
               | chat_input: new_input,
                 chat_cursor: String.length(new_input)
             }), []}

          _ ->
            {state, []}
        end

      :chat_cancel ->
        {%{
           state
           | chat_input: "",
             chat_input_extra_lines: [],
             chat_cursor: 0,
             chat_ghost: nil
         }, []}

      :chat_scroll_down ->
        new_scroll = max(0, state.chat_scroll - 5)
        {%{state | chat_scroll: new_scroll}, []}

      :chat_scroll_up ->
        max_scroll = compute_chat_max_scroll(state)
        new_scroll = min(max_scroll, state.chat_scroll + 5)
        {%{state | chat_scroll: new_scroll}, []}

      _ ->
        {state, []}
    end
  end

  # --- Room event ingestion ---

  defp handle_room_event({:user_message, msg}, state) do
    state
    |> append_chat_entries(message_to_entries(msg))
    |> Map.put(:chat_streams, %{})
    |> recompute_chat_total_lines()
    |> auto_pin_to_bottom()
  end

  defp handle_room_event({:agent_message, msg}, state) do
    agent_id = msg.sender.id
    entries = message_to_entries(msg)

    state
    |> Map.update!(:chat_streams, &Map.delete(&1, agent_id))
    |> update_agent_ctx(agent_id, msg)
    |> append_chat_entries(entries)
    |> recompute_chat_total_lines()
    |> auto_pin_to_bottom()
  end

  defp handle_room_event({:agent_streaming, agent_id, delta}, state) do
    name = chat_agent_name(state, agent_id)

    current =
      Map.get(state.chat_streams, agent_id, %{
        name: name,
        committed: "",
        buffer: "",
        started_at: System.monotonic_time()
      })

    combined = current.buffer <> delta

    {new_committed, new_buffer} =
      case String.split(combined, "\n\n") do
        [single] ->
          {current.committed, single}

        parts ->
          {complete, [partial]} = Enum.split(parts, length(parts) - 1)
          flushed = Enum.join(complete, "\n\n") <> "\n\n"
          {current.committed <> flushed, partial}
      end

    updated = %{current | committed: new_committed, buffer: new_buffer}
    streams = Map.put(state.chat_streams, agent_id, updated)

    %{state | chat_streams: streams}
    |> maybe_start_animation_tick()
    |> recompute_chat_total_lines()
    |> auto_pin_to_bottom()
  end

  defp handle_room_event({:agent_tool_call, agent_id, tool_name, input}, state) do
    nick = chat_agent_name(state, agent_id)
    text = "#{tool_name}(#{format_tool_input(input)})"
    entry = {:action, %{nick: nick, text: text, color: :muted, ts: DateTime.utc_now()}}

    state
    |> append_chat_entries([entry])
    |> recompute_chat_total_lines()
    |> auto_pin_to_bottom()
  end

  # Activation is conveyed visually by the side-panel bullets and the
  # thinking-ellipsis indicator — no need for a transcript line.
  defp handle_room_event({:agents_activated, _count}, state), do: state

  defp handle_room_event({:agent_passed, agent_id}, state) do
    nick = chat_agent_name(state, agent_id)

    state
    |> Map.update!(:chat_streams, &Map.delete(&1, agent_id))
    |> append_system("#{nick} passed", :info)
  end

  defp handle_room_event({:agent_joined, agent_id}, state) do
    nick = chat_agent_name(state, agent_id)
    append_system(state, "#{nick} joined", :info)
  end

  defp handle_room_event({:agent_left, agent_id}, state) do
    nick = chat_agent_name(state, agent_id)
    append_system(state, "#{nick} left", :info)
  end

  defp handle_room_event({:agent_handoff, agent_id, delib_id}, state) do
    nick = chat_agent_name(state, agent_id)

    state
    |> reset_agent_ctx(agent_id)
    |> append_system("#{nick} handed off → [[#{delib_id}]]", :info)
  end

  defp handle_room_event(:budget_exhausted, state) do
    append_system(state, "budget exhausted — /continue to grant more rounds", :warning)
  end

  defp handle_room_event(:continued, state) do
    append_system(state, "budget reset", :info)
  end

  defp handle_room_event(_, state), do: state

  defp append_chat_entries(state, entries) do
    %{state | chat_messages: state.chat_messages ++ entries}
  end

  # If user is pinned to bottom (chat_scroll == 0), keep them there.
  # Nothing to do explicitly — chat_scroll already 0 means follow.
  defp auto_pin_to_bottom(state), do: state

  defp chat_agent_name(state, agent_id) do
    case Enum.find(state.chat_agents, fn %{id: id} -> id == agent_id end) do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> agent_basename(agent_id)
    end
  end

  defp update_agent_ctx(state, agent_id, msg) do
    case Map.get(msg, :usage) do
      %{context_window: cw, session_tokens: st} when is_integer(cw) and cw > 0 ->
        pct = round(st / cw * 100)
        update_chat_agent(state, agent_id, %{ctx_pct: pct})

      _ ->
        state
    end
  end

  defp reset_agent_ctx(state, agent_id) do
    update_chat_agent(state, agent_id, %{ctx_pct: 0})
  end

  defp update_chat_agent(state, agent_id, fields) do
    agents =
      Enum.map(state.chat_agents, fn agent ->
        if agent.id == agent_id, do: Map.merge(agent, fields), else: agent
      end)

    %{state | chat_agents: agents}
  end

  defp format_tool_input(%{} = input) do
    cond do
      Map.has_key?(input, "query") -> inspect(Map.get(input, "query"))
      Map.has_key?(input, :query) -> inspect(Map.get(input, :query))
      Map.has_key?(input, "id") -> inspect(Map.get(input, "id"))
      Map.has_key?(input, :id) -> inspect(Map.get(input, :id))
      Map.has_key?(input, "title") -> inspect(Map.get(input, "title"))
      true -> "..."
    end
  end

  defp format_tool_input(_), do: ""

  # --- View ---

  @impl true
  def view(%{mode: :chat} = state), do: chat_view(state)
  def view(state), do: records_view(state)

  defp records_view(state) do
    w = state.width
    h = state.height
    # Non-body: header(1) + search(1) + separator(1) + blank(1) + blank(1) + status(1) = 6
    body = max(1, h - 6)
    list_h = max(1, div(body, 3))
    preview_h = max(1, body - list_h)

    # In command mode, the dropdown replaces the record list
    list_or_dropdown =
      if state.command_mode do
        render_command_dropdown(state, w, list_h)
      else
        render_list(state, w, list_h)
      end

    sep = text(String.duplicate("─", w), Theme.separator())

    lines =
      [render_header(state, w)] ++
        [render_search(state, w)] ++
        [sep] ++
        list_or_dropdown ++
        [text("", nil)] ++
        render_preview(state, w, preview_h) ++
        [text("", nil)] ++
        [render_status(state, w)]

    stack(:vertical, lines)
  end

  # --- Chat view ---

  defp chat_view(state) do
    w = state.width
    h = state.height

    # Layout regions (top → bottom):
    # 1) chat header             (1)
    # 2) transcript region       (flex)
    #    - wide:   transcript │ side panel  (side-by-side)
    #    - narrow: full-width transcript
    # 3) command dropdown        (only when command_mode)
    # 4) status strip            (1, narrow mode only)
    # 5) input box border        (1)
    # 6) input box               (1+, capped by extras)
    # 7) status bar              (1)
    side_panel? = use_side_panel?(state)
    strip_h = if side_panel?, do: 0, else: 1
    dropdown_h = if state.command_mode, do: chat_dropdown_height(state), else: 0
    # +1 for the blank row above the status bar
    chrome = 4 + strip_h + dropdown_h + input_box_height(state)
    transcript_h = max(1, h - chrome)

    transcript_region =
      if side_panel? do
        render_chat_split(state, w, transcript_h)
      else
        render_chat_transcript(state, w, transcript_h)
      end

    dropdown = if state.command_mode, do: render_chat_dropdown(state, w, dropdown_h), else: []
    input_lines = render_chat_input_box(state, w)
    strip = if side_panel?, do: [], else: [render_chat_status_strip(state, w)]

    sep_line = text(String.duplicate("─", w), Theme.separator())

    lines =
      [render_chat_header(state, w)] ++
        transcript_region ++
        dropdown ++
        strip ++
        [sep_line] ++
        input_lines ++
        [text(String.duplicate(" ", w), nil)] ++
        [render_chat_status(state, w)]

    stack(:vertical, lines)
  end

  # Threshold for showing the right-side agents column.
  @side_panel_min_width 80
  @side_panel_width 18

  defp use_side_panel?(state), do: state.width >= @side_panel_min_width

  # Side-by-side layout: transcript on the left, agents column on the
  # right separated by a vertical bar. Both columns have the same height
  # (`h`); each row is a horizontal stack so TermUI lays them side by side.
  defp render_chat_split(state, w, h) do
    panel_w = @side_panel_width
    sep_w = 1
    trans_w = max(10, w - panel_w - sep_w)

    transcript_rows = render_chat_transcript(state, trans_w, h)
    panel_rows = render_chat_side_panel(state, panel_w, h)

    sep_row = text("│", Theme.separator())

    Enum.zip_with([transcript_rows, panel_rows], fn [t_row, p_row] ->
      stack(:horizontal, [t_row, sep_row, p_row])
    end)
  end

  # Right-side agents column. Each agent gets one row:
  #   ● scout         23%
  # Filled bullet (●) when streaming, hollow (○) when idle.
  defp render_chat_side_panel(state, w, h) do
    active_ids = Map.keys(state.chat_streams)

    rows =
      Enum.map(state.chat_agents, fn agent ->
        active? = agent.id in active_ids
        bullet = if active?, do: "●", else: "○"
        bullet_style = Theme.agent_color(agent.id)

        name = agent.name || agent_basename(agent.id)
        ctx = if agent.ctx_pct > 0, do: "#{agent.ctx_pct}%", else: "--"

        # Layout: " ● name<pad>ctx " totalling w cells.
        # Bullet span: " ● " (3 cells)
        # Trailing margin: 1 cell
        avail = max(1, w - 3 - String.length(ctx) - 1)
        name_str = String.slice(name, 0, avail)
        name_padded = String.pad_trailing(name_str, avail)

        name_style = if active?, do: Theme.normal(), else: Theme.muted()

        stack(:horizontal, [
          text(" " <> bullet <> " ", bullet_style),
          text(name_padded <> ctx <> " ", name_style)
        ])
      end)

    # Clamp to h, then pad with blank rows so the column matches the
    # transcript height for clean horizontal stacking.
    rows = Enum.take(rows, h)
    blank = text(String.duplicate(" ", w), nil)
    rows ++ List.duplicate(blank, max(0, h - length(rows)))
  end

  # Narrow-mode 1-row strip: a horizontal list of bullets+nicks above
  # the input box, replacing the side panel.
  defp render_chat_status_strip(state, w) do
    active_ids = Map.keys(state.chat_streams)

    case state.chat_agents do
      [] ->
        text(String.pad_trailing(" present: (none)", w), Theme.muted())

      agents ->
        parts =
          Enum.map(agents, fn agent ->
            bullet = if agent.id in active_ids, do: "●", else: "○"
            bullet <> (agent.name || agent_basename(agent.id))
          end)

        line = " present: " <> Enum.join(parts, " ")
        clipped = String.slice(line, 0, w)
        pad = max(0, w - String.length(clipped))
        text(clipped <> String.duplicate(" ", pad), Theme.muted())
    end
  end

  # Number of rows the chat-mode command dropdown should occupy.
  # We size to the number of matches (capped) so the dropdown is compact.
  defp chat_dropdown_height(state) do
    cmds = filtered_commands(state.command_input, state.mode)
    max(1, min(length(cmds), 6))
  end

  defp render_chat_dropdown(state, w, h) do
    cmds = filtered_commands(state.command_input, state.mode)

    rows =
      cmds
      |> Enum.take(h)
      |> Enum.with_index()
      |> Enum.map(fn {{name, desc}, idx} ->
        selected = idx == state.command_selected
        content = " /#{name}  #{desc}"
        clipped = String.slice(content, 0, w)
        pad = max(0, w - String.length(clipped))
        style = if selected, do: Theme.selected(), else: Theme.normal()
        text(clipped <> String.duplicate(" ", pad), style)
      end)

    # Pad to fixed dropdown height to keep layout stable
    padding = List.duplicate(text(String.duplicate(" ", w), nil), max(0, h - length(rows)))
    rows ++ padding
  end

  defp render_chat_header(state, w) do
    left = " egghead"
    room = state.chat_room_id || "(no room)"
    right = "CHAT · #{room} "
    pad = max(0, w - String.length(left) - String.length(right))
    text(left <> String.duplicate(" ", pad) <> right, Theme.header_bar())
  end

  defp render_chat_transcript(state, w, h) do
    entries = chat_display_entries(state)
    lines = Egghead.TUI.ChatRender.render_entries(entries, w)
    total = length(lines)

    # Bottom-anchored: when chat_scroll == 0, show the LAST h lines.
    # When chat_scroll > 0, the user has scrolled up by that many lines.
    skip = max(0, total - h - state.chat_scroll)
    visible = lines |> Enum.drop(skip) |> Enum.take(h)

    rendered = Enum.map(visible, &render_chat_line(&1, w))

    padding_count = max(0, h - length(visible))
    padding = List.duplicate(text(String.duplicate(" ", w), nil), padding_count)

    # When transcript is shorter than viewport, padding goes ABOVE
    # the content so messages bottom-align.
    padding ++ rendered
  end

  # Single-style line: a `{string, style}` tuple from ChatRender.
  defp render_chat_line({content, style}, w) do
    clean = String.replace(content, "\n", " ")
    padded = clean |> String.slice(0, w) |> String.pad_trailing(w)
    text(padded, style || Theme.normal())
  end

  # Multi-span line: a list of `{string, style}` tuples to be composed
  # horizontally. Used for right-aligned timestamps.
  defp render_chat_line(spans, w) when is_list(spans) do
    used =
      Enum.reduce(spans, 0, fn {t, _}, acc -> acc + String.length(t) end)

    rendered =
      Enum.map(spans, fn {t, s} ->
        clean = String.replace(t, "\n", " ")
        text(clean, s || Theme.normal())
      end)

    pad = max(0, w - used)
    tail = text(String.duplicate(" ", pad), nil)
    stack(:horizontal, rendered ++ [tail])
  end

  defp render_chat_input_box(state, w) do
    if state.command_mode do
      content = " /" <> state.command_input <> "▌"
      pad = max(0, w - String.length(content))
      [text(content <> String.duplicate(" ", pad), Theme.prompt())]
    else
      # Multi-line input: extras are previous lines (in order), chat_input
      # is the current line being edited. Only the active (last) line
      # gets the cursor inserted at chat_cursor.
      all_lines = state.chat_input_extra_lines ++ [state.chat_input]
      last_idx = length(all_lines) - 1

      Enum.with_index(all_lines)
      |> Enum.map(fn {line, idx} ->
        prefix = if idx == 0, do: " ❯ ", else: "   "
        active? = idx == last_idx

        body =
          if active? do
            cursor_at = min(state.chat_cursor, String.length(line))
            {before, rest} = String.split_at(line, cursor_at)
            ghost = if is_binary(state.chat_ghost), do: state.chat_ghost, else: ""
            before <> "▌" <> rest <> ghost
          else
            line
          end

        base = prefix <> body
        base = String.slice(base, 0, w)
        pad = max(0, w - String.length(base))
        text(base <> String.duplicate(" ", pad), Theme.prompt())
      end)
    end
  end

  defp render_chat_status(state, w) do
    line =
      if state.command_mode do
        " CMD │ ↑↓ select │ ⏎ execute │ esc cancel"
      else
        budget =
          case state.chat_budget do
            %{remaining: r, total: t} -> " │ budget #{r}/#{t}"
            _ -> ""
          end

        " CHAT │ ⏎ send │ ^j newline │ esc records │ / cmd │ ^q quit" <> budget
      end

    line = String.slice(line, 0, w)
    pad = max(0, w - String.length(line))
    text(line <> String.duplicate(" ", pad), Theme.status_bar_line())
  end

  defp input_box_height(state) do
    extras = length(state.chat_input_extra_lines)
    1 + min(extras, 4)
  end

  # --- Header (dark background band) ---

  defp render_header(state, w) do
    left = " egghead"
    count = length(state.results)
    agent_count = length(state.agents)
    filter_label = if state.show_all_classes, do: "all", else: "durable"
    right = "#{filter_label} · #{count} records · #{agent_count} agents"
    pad = max(0, w - String.length(left) - String.length(right))
    text(left <> String.duplicate(" ", pad) <> right, Theme.header_bar())
  end

  # --- Search bar ---

  defp render_search(state, w) do
    {prompt_str, input} =
      if state.command_mode do
        {" /", state.command_input}
      else
        {" ❯ ", state.query}
      end

    content = prompt_str <> input <> "▌"
    pad = max(0, w - String.length(content))
    text(content <> String.duplicate(" ", pad), Theme.prompt())
  end

  # --- Command autocomplete dropdown ---

  defp render_command_dropdown(state, w, list_h) do
    cmds = filtered_commands(state.command_input, state.mode)
    unselected = Theme.normal()

    rows =
      cmds
      |> Enum.take(list_h)
      |> Enum.with_index()
      |> Enum.map(fn {{name, desc}, idx} ->
        selected = idx == state.command_selected
        content = " /#{name}  #{desc}"
        pad = max(0, w - String.length(content))

        if selected do
          text(content <> String.duplicate(" ", pad), Theme.selected())
        else
          text(content <> String.duplicate(" ", pad), unselected)
        end
      end)

    # Pad remaining rows with explicit bg to clear any leftover styles
    padding =
      List.duplicate(
        text(String.duplicate(" ", w), unselected),
        max(0, list_h - length(rows))
      )

    rows ++ padding
  end

  # --- Note list ---

  defp render_list(state, w, list_h) do
    visible =
      state.results
      |> Enum.drop(state.scroll_offset)
      |> Enum.take(list_h)
      |> Enum.with_index(state.scroll_offset)

    record_rows =
      Enum.map(visible, fn {record, idx} ->
        render_list_row(record, idx == state.selected, w, state)
      end)

    # Phantom "Create" row appears when query has no exact match
    phantom_rows =
      case creation_target(state) do
        nil ->
          []

        {title, slug} ->
          phantom_idx = length(state.results)

          if length(record_rows) < list_h do
            [render_phantom_row(title, slug, phantom_idx == state.selected, w)]
          else
            []
          end
      end

    rows = record_rows ++ phantom_rows
    padding = List.duplicate(text("", nil), max(0, list_h - length(rows)))
    rows ++ padding
  end

  defp render_phantom_row(title, slug, selected, w) do
    label =
      if title == slug do
        " + Create \"#{title}\""
      else
        " + Create \"#{title}\"  → #{slug}"
      end

    pad = max(0, w - String.length(label))
    style = if selected, do: Theme.selected(), else: Theme.accent()
    text(label <> String.duplicate(" ", pad), style)
  end

  defp render_list_row(record, selected, w, state) do
    title = record.title || record.id
    time = format_time(record.updated, state.date_format)
    time_str = " #{time} "
    title_max = max(1, w - String.length(time_str) - 2)
    title_str = String.pad_trailing(String.slice(title, 0, title_max), title_max)

    if selected do
      text(" " <> title_str <> time_str, Theme.selected())
    else
      stack(:horizontal, [
        text(" " <> title_str, Theme.normal()),
        text(time_str, Theme.muted())
      ])
    end
  end

  # --- Preview ---

  defp render_preview(%{preview: nil}, w, preview_h) do
    label = render_preview_label([{"(no selection)", :muted}], w)
    [label | List.duplicate(text("", nil), max(0, preview_h - 1))]
  end

  defp render_preview(%{preview: record, preview_scroll: scroll} = state, w, preview_h) do
    body = record.body || "(no content)"
    total_lines = Egghead.TUI.Markdown.render(body, w - 4)
    total_count = length(total_lines)

    # Reserve lines for links, gap, and scroll indicator
    links_lines = render_links(state, w)
    links_gap = if links_lines != [], do: 1, else: 0
    content_h = max(0, preview_h - 1 - length(links_lines) - links_gap)

    # Clamp scroll
    max_scroll = max(0, total_count - content_h)
    scroll = min(scroll, max_scroll)

    # Scroll position indicator
    scroll_segment =
      if total_count > content_h do
        pos = if max_scroll > 0, do: round(scroll / max_scroll * 100), else: 0
        ["#{scroll + 1}-#{min(scroll + content_h, total_count)}/#{total_count} (#{pos}%)"]
      else
        ["#{total_count}L"]
      end

    class_str = record.class |> to_string()

    segments =
      [{record.id, :normal}, {class_str, :muted}] ++
        Enum.map(scroll_segment, &{&1, :muted})

    label = render_preview_label(segments, w)

    # If a body wikilink is selected, find which line(s) contain it
    # and highlight them.
    selected_body_target = selected_body_target(state)

    # Pre-compute scrollbar geometry once per render (not per row).
    # bar_size: thumb height proportional to viewport/total ratio.
    # travel: range of valid bar_start positions so the thumb fits in content_h.
    {bar_start, bar_size} =
      if total_count > content_h do
        size = max(1, round(content_h * content_h / total_count))
        travel = max(0, content_h - size)
        start = if max_scroll > 0, do: round(scroll / max_scroll * travel), else: 0
        {start, size}
      else
        {0, 0}
      end

    # Render visible lines — each exactly w characters, with scrollbar on right edge
    visible =
      total_lines
      |> Enum.drop(scroll)
      |> Enum.take(content_h)
      |> Enum.with_index()
      |> Enum.map(fn {{content, style}, idx} ->
        is_thumb = bar_size > 0 and idx >= bar_start and idx < bar_start + bar_size

        # Highlight line if it contains the selected wikilink
        style =
          if selected_body_target && line_contains_wikilink?(content, selected_body_target) do
            Theme.selected()
          else
            style
          end

        # Content padded to fixed width, scrollbar as separate styled node.
        clean = content |> String.replace("\n", " ")
        padded = (" " <> clean) |> String.slice(0, w - 1) |> String.pad_trailing(w - 1)
        scrollbar_char = if is_thumb, do: "▐", else: " "

        stack(:horizontal, [
          text(padded, style),
          text(scrollbar_char, Theme.separator())
        ])
      end)

    padding = List.duplicate(text("", nil), max(0, content_h - length(visible)))
    gap = if links_lines != [], do: [text("", nil)], else: []
    [label] ++ visible ++ padding ++ gap ++ links_lines
  end

  defp render_preview_label(segments, w) do
    # segments :: [{text, :normal | :muted}]
    # Render as: " ── seg1 ── seg2 ── seg3 ──────... "
    sep = " ── "

    body_spans =
      segments
      |> Enum.with_index()
      |> Enum.flat_map(fn {{txt, kind}, idx} ->
        prefix = if idx == 0, do: " ── ", else: sep
        style = if kind == :normal, do: Theme.normal(), else: Theme.muted()
        [text(prefix, Theme.separator()), text(txt, style)]
      end)

    used =
      Enum.reduce(body_spans, 0, fn span, acc ->
        acc + String.length(span_text(span))
      end)

    pad = max(0, w - used - 1)
    tail = text(" " <> String.duplicate("─", pad), Theme.separator())
    stack(:horizontal, body_spans ++ [tail])
  end

  defp span_text(%{content: t}) when is_binary(t), do: t
  defp span_text(_), do: ""

  defp render_links(%{preview_links: []}, _w), do: []

  defp render_links(%{preview_links: links, link_index: link_index}, w) do
    # Body wikilinks are highlighted in the body itself, not in the footer.
    fwd = Enum.filter(links, fn {_, _, type} -> type == :forward end)
    back = Enum.filter(links, fn {_, _, type} -> type == :backlink end)

    fwd_line = render_link_line("Links", fwd, links, link_index, w)
    back_line = render_link_line("Backlinks", back, links, link_index, w)

    fwd_line ++ back_line
  end

  defp render_link_line(_label, [], _all, _selected, _w), do: []

  defp render_link_line(label, items, all_links, selected_idx, _w) do
    spans =
      items
      |> Enum.flat_map(fn {id, display, _type} ->
        global_idx = Enum.find_index(all_links, fn {lid, _, _} -> lid == id end)
        is_selected = global_idx == selected_idx
        style = if is_selected, do: Theme.selected(), else: Theme.link()
        [text("[[#{display}]]", style), text("  ", nil)]
      end)

    # Trim trailing spacer
    spans = if spans != [], do: Enum.slice(spans, 0..-2//1), else: spans

    content = [text(" #{label}: ", Theme.muted()) | spans]
    [stack(:horizontal, content)]
  end

  # --- Status bar (dark background band) ---

  defp render_status(state, w) do
    left =
      cond do
        state.command_mode ->
          " CMD │ ↑↓ select │ ⏎ execute │ esc cancel"

        state.link_index != nil ->
          back = if state.nav_history != [], do: " │ ⌫ back", else: ""
          " LINK │ tab cycle │ ⏎ follow │ esc deselect#{back} │ ^q quit"

        state.selected == phantom_index(state) ->
          " NEW │ ⏎ create │ ↑ back to results │ ^q quit"

        true ->
          " REC │ ↑↓ │ ⏎ edit │ tab links │ / cmd │ ^f filter │ ^t date │ ^q quit"
      end

    pad = max(0, w - String.length(left))
    text(left <> String.duplicate(" ", pad), Theme.status_bar_line())
  end

  # --- Key routing ---

  defp records_event(event, state) do
    case event.key do
      :up ->
        {:msg, :move_up}

      :down ->
        {:msg, :move_down}

      :enter ->
        if state.link_index != nil, do: {:msg, :follow_link}, else: {:msg, :open_editor}

      :escape ->
        if state.link_index != nil, do: {:msg, :link_deselect}, else: :ignore

      :backspace ->
        if state.query == "" and state.nav_history != [],
          do: {:msg, :nav_back},
          else: {:msg, :backspace}

      :page_down ->
        {:msg, :preview_scroll_down}

      :page_up ->
        {:msg, :preview_scroll_up}

      _ ->
        cond do
          # Tab: cycle forward through links in preview
          event.key == :tab ->
            {:msg, :link_next}

          # Ctrl+F: toggle durable/all filter
          event.key == "f" and :ctrl in event.modifiers ->
            {:msg, :toggle_filter}

          # Ctrl+T: toggle date format (relative ↔ iso8601)
          event.key == "t" and :ctrl in event.modifiers ->
            {:msg, :toggle_date_format}

          # Ctrl combos for preview scroll
          event.key == "j" and :ctrl in event.modifiers ->
            {:msg, :preview_scroll_down}

          event.key == "k" and :ctrl in event.modifiers ->
            {:msg, :preview_scroll_up}

          event.key == "n" and :ctrl in event.modifiers ->
            {:msg, :preview_scroll_down}

          event.key == "p" and :ctrl in event.modifiers ->
            {:msg, :preview_scroll_up}

          true ->
            case event.char do
              "/" when state.query == "" -> {:msg, :enter_command}
              # Ignore "[" — orphaned CSI introducer from split escape sequences
              # (e.g. ESC arrives alone via timeout, then [B arrives as two chars)
              "[" -> :ignore
              c when is_binary(c) and c != "" -> {:msg, {:char, c}}
              _ -> :ignore
            end
        end
    end
  end

  defp chat_event(event, state) do
    case event.key do
      :enter ->
        {:msg, :chat_send}

      :escape ->
        {:msg, :chat_leave}

      :backspace ->
        {:msg, :chat_backspace}

      :left ->
        {:msg, :chat_cursor_left}

      :right ->
        {:msg, :chat_cursor_right}

      :home ->
        {:msg, :chat_cursor_home}

      :end_ ->
        {:msg, :chat_cursor_end}

      :tab ->
        if is_binary(state.chat_ghost), do: {:msg, :chat_accept_ghost}, else: :ignore

      _ ->
        cond do
          # Ctrl+J: insert newline (push current line to extras, start fresh)
          event.key == "j" and :ctrl in event.modifiers ->
            {:msg, :chat_newline}

          # Ctrl+N: scroll down (toward newer messages)
          event.key == "n" and :ctrl in event.modifiers ->
            {:msg, :chat_scroll_down}

          # Ctrl+P: scroll up (toward older messages)
          event.key == "p" and :ctrl in event.modifiers ->
            {:msg, :chat_scroll_up}

          # Ctrl+G: cancel (clear input + ghost)
          event.key == "g" and :ctrl in event.modifiers ->
            {:msg, :chat_cancel}

          # Readline-style cursor movement
          event.key == "a" and :ctrl in event.modifiers ->
            {:msg, :chat_cursor_home}

          event.key == "e" and :ctrl in event.modifiers ->
            {:msg, :chat_cursor_end}

          event.key == "b" and :ctrl in event.modifiers ->
            {:msg, :chat_cursor_left}

          event.key == "f" and :ctrl in event.modifiers ->
            {:msg, :chat_cursor_right}

          # Readline-style kill operations
          event.key == "k" and :ctrl in event.modifiers ->
            {:msg, :chat_kill_line}

          event.key == "u" and :ctrl in event.modifiers ->
            {:msg, :chat_kill_to_start}

          event.key == "w" and :ctrl in event.modifiers ->
            {:msg, :chat_kill_word}

          event.key == "d" and :ctrl in event.modifiers ->
            {:msg, :chat_delete}

          true ->
            case event.char do
              # / on empty input enters command mode (chat-aware palette)
              "/" when state.chat_input == "" and state.chat_input_extra_lines == [] ->
                {:msg, :enter_command}

              # Ignore orphan CSI fragments
              "[" ->
                :ignore

              c when is_binary(c) and c != "" ->
                {:msg, {:chat_char, c}}

              _ ->
                :ignore
            end
        end
    end
  end

  defp command_event(event, _state) do
    case event.key do
      :enter ->
        {:msg, :command_execute}

      :backspace ->
        {:msg, :command_backspace}

      :up ->
        {:msg, :command_up}

      :down ->
        {:msg, :command_down}

      _ ->
        case event.char do
          "[" -> :ignore
          c when is_binary(c) and c != "" -> {:msg, {:command_char, c}}
          _ -> :ignore
        end
    end
  end

  # --- Search ---

  defp search(state, query) do
    results = filter_and_sort(state.all_records, state.show_all_classes, query)
    new_state = %{state | query: query, results: results, selected: 0, scroll_offset: 0}

    {set_preview(new_state, preview_for_selection(new_state, 0)), []}
  end

  defp filter_and_sort(records, show_all, query) do
    records
    |> then(fn rs ->
      if show_all, do: rs, else: Enum.filter(rs, &(&1.class == :durable))
    end)
    |> then(fn rs ->
      if query == "" do
        rs
      else
        q = String.downcase(query)

        Enum.filter(rs, fn r ->
          String.contains?(String.downcase(r.id), q) ||
            (r.title && String.contains?(String.downcase(r.title), q)) ||
            Enum.any?(r.tags || [], &String.contains?(String.downcase(&1), q))
        end)
      end
    end)
    |> Enum.sort_by(& &1.updated, :desc)
  end

  # --- Preview loading ---

  defp load_preview(results, index) do
    case Enum.at(results, index) do
      nil ->
        nil

      record ->
        case Egghead.get_record(record.id) do
          {:ok, full} -> full
          _ -> record
        end
    end
  end

  # Returns the record to preview for the given selection index.
  # When the phantom create row is selected, returns a synthetic Record
  # with an instructional body. Otherwise delegates to load_preview.
  defp preview_for_selection(state, idx) do
    cond do
      idx == phantom_index(state) ->
        {title, slug} = creation_target(state)

        %Egghead.Record{
          id: slug,
          title: title,
          body: """
          ## Create new record

          **Title:** #{title}
          **Id:** `#{slug}`

          Press **Enter** to create this record and open in $EDITOR.
          The title is slugified to derive the id. Slashes create
          subdirectories: `agents/scout` → `records/agents/scout.md`.
          """,
          class: :durable,
          tags: [],
          links: []
        }

      true ->
        load_preview(state.results, idx)
    end
  end

  # --- Search-as-create (Notational Velocity pattern) ---

  # Returns the target {title, slug} for a phantom create row, or nil.
  # The user types a free-form title in the search bar. We slugify it
  # to derive the id. If the slugified id matches an existing record,
  # no phantom is shown (the existing record is already in the list).
  defp creation_target(state) do
    title = String.trim(state.query)

    cond do
      title == "" ->
        nil

      true ->
        slug = slugify(title)

        cond do
          slug == "" -> nil
          Enum.any?(state.results, &(&1.id == slug)) -> nil
          true -> {title, slug}
        end
    end
  end

  # Convert a free-form title to a record id slug.
  # - Lowercase
  # - Strip non-(alnum/_/slash/dash) → dash
  # - Collapse runs of dashes
  # - Trim leading/trailing dashes per path segment
  # Slashes are preserved to allow path-style ids: "Agents / Scout" → "agents/scout"
  defp slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r{[^a-z0-9_/-]+}, "-")
    |> String.replace(~r{-+}, "-")
    |> String.split("/")
    |> Enum.map(&String.trim(&1, "-"))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("/")
  end

  # Total list length including phantom create row when present
  defp list_total(state) do
    length(state.results) + if creation_target(state), do: 1, else: 0
  end

  # Index of the phantom create row (one past the end of results), or nil
  defp phantom_index(state) do
    if creation_target(state), do: length(state.results), else: nil
  end

  # Set preview and compute navigable links (forward + backlinks).
  # Also pre-computes the rendered line count so scroll handlers can
  # clamp without re-rendering. Resets link_index and preview_scroll.
  defp set_preview(state, preview) do
    links = collect_preview_links(preview)
    total = preview_line_count(preview, max(1, state.width - 4))

    %{
      state
      | preview: preview,
        preview_scroll: 0,
        link_index: nil,
        preview_links: links,
        preview_total_lines: total
    }
  end

  defp preview_line_count(nil, _w), do: 0

  defp preview_line_count(record, w) do
    body = record.body || ""
    body |> Egghead.TUI.Markdown.render(w) |> length()
  end

  # When a body wikilink is selected, find its line in the rendered preview
  # and adjust preview_scroll to bring it into the viewport.
  defp scroll_to_link(state) do
    with %{link_index: idx} when not is_nil(idx) <- state,
         {target, _, :body} <- Enum.at(state.preview_links, idx),
         %{preview: record} when not is_nil(record) <- state,
         body when is_binary(body) <- record.body,
         lines <- Egghead.TUI.Markdown.render(body, max(1, state.width - 4)),
         line_num when not is_nil(line_num) <-
           Egghead.TUI.Markdown.find_wikilink_line(lines, target) do
      content_h = compute_content_h(state)
      max_scroll = compute_max_scroll(state)

      new_scroll =
        cond do
          line_num < state.preview_scroll ->
            line_num

          line_num >= state.preview_scroll + content_h ->
            min(max_scroll, line_num - div(content_h, 2))

          true ->
            state.preview_scroll
        end

      %{state | preview_scroll: new_scroll}
    else
      _ -> state
    end
  end

  # Returns the target id of the currently-selected body wikilink, or nil
  defp selected_body_target(state) do
    case Enum.at(state.preview_links || [], state.link_index || -1) do
      {target, _, :body} -> target
      _ -> nil
    end
  end

  defp line_contains_wikilink?(line_text, target) do
    String.contains?(line_text, "[[#{target}]]") or
      String.contains?(line_text, "[[#{target}|")
  end

  defp compute_content_h(state) do
    body_h = max(1, state.height - 6)
    list_h = max(1, div(body_h, 3))
    preview_h = max(1, body_h - list_h)
    links_n = link_lines_count(state)
    links_gap = if links_n > 0, do: 1, else: 0
    max(0, preview_h - 1 - links_n - links_gap)
  end

  # Conservative max scroll based on state.height. Used by scroll handlers
  # to clamp preview_scroll. Mirrors the layout math in render_preview.
  defp compute_max_scroll(state) do
    body_h = max(1, state.height - 6)
    list_h = max(1, div(body_h, 3))
    preview_h = max(1, body_h - list_h)
    links_n = link_lines_count(state)
    links_gap = if links_n > 0, do: 1, else: 0
    content_h = max(0, preview_h - 1 - links_n - links_gap)
    max(0, state.preview_total_lines - content_h)
  end

  defp link_lines_count(state) do
    fwd = Enum.any?(state.preview_links, fn {_, _, type} -> type == :forward end)
    back = Enum.any?(state.preview_links, fn {_, _, type} -> type == :backlink end)
    if(fwd, do: 1, else: 0) + if back, do: 1, else: 0
  end

  defp collect_preview_links(nil), do: []

  defp collect_preview_links(record) do
    forward = Enum.map(record.links || [], fn id -> {id, id, :forward} end)

    body =
      Enum.map(record.wikilinks || [], fn %{target: t, display: d} ->
        {t, d || t, :body}
      end)

    backlinks =
      try do
        Egghead.find_backlinks(record.id)
        |> Enum.map(fn r -> {r.id, r.title || r.id, :backlink} end)
      catch
        _, _ -> []
      end

    forward_ids = MapSet.new(record.links || [])

    # Body wikilinks: dedupe against the record itself and forward links
    filtered_body =
      body
      |> Enum.reject(fn {id, _, _} ->
        id == record.id || MapSet.member?(forward_ids, id)
      end)
      |> Enum.uniq_by(fn {id, _, _} -> id end)

    body_ids = MapSet.new(Enum.map(filtered_body, fn {id, _, _} -> id end))

    filtered_back =
      Enum.reject(backlinks, fn {id, _, _} ->
        id == record.id || MapSet.member?(forward_ids, id) || MapSet.member?(body_ids, id)
      end)

    # Order: forward (footer), body (in-document order), backlinks (footer)
    forward ++ filtered_body ++ filtered_back
  end

  # --- Commands ---

  @records_commands [
    {"quit", "Exit the TUI"},
    {"help", "Show keybindings & commands"},
    {"new", "Create a new record"},
    {"chat", "Enter chat mode"},
    {"system", "Agent diagnostics"},
    {"debug", "Dump buffer to /tmp/egghead_render.txt"}
  ]

  @chat_commands [
    {"save", "Save room as deliberation"},
    {"continue", "Reset turn budget"},
    {"handoff", "Hand off to an agent (provide id as arg)"},
    {"leave", "Return to records mode"},
    {"help", "Show keybindings & commands"},
    {"quit", "Exit the TUI"}
  ]

  defp commands_for(:chat), do: @chat_commands
  defp commands_for(_), do: @records_commands

  defp filtered_commands(input, mode) do
    # Match against the command name only (before any space).
    head =
      input
      |> String.split(" ", parts: 2)
      |> List.first()
      |> String.downcase()

    Enum.filter(commands_for(mode), fn {name, _} -> String.starts_with?(name, head) end)
  end

  defp execute_command(state) do
    raw_input = state.command_input
    cmds = filtered_commands(raw_input, state.mode)
    selected = Enum.at(cmds, state.command_selected)

    # Capture argument (e.g. "handoff scout" → arg "scout") before clearing
    arg =
      case String.split(raw_input, " ", parts: 2) do
        [_, rest] -> String.trim(rest)
        _ -> ""
      end

    state = %{state | command_mode: false, command_input: "", command_arg: arg}

    case selected do
      {"quit", _} ->
        TermUI.Runtime.shutdown(self())
        {state, [:quit]}

      {"debug", _} ->
        Egghead.TUI.TestHelpers.dump_live_buffer()
        {state, []}

      {"help", _} ->
        {set_preview(state, help_record()), []}

      {"new", _} ->
        create_and_edit_record(state)

      {"chat", _} ->
        enter_chat_mode(state)

      {"leave", _} ->
        leave_chat_mode(state)

      {"save", _} ->
        chat_save(state)

      {"continue", _} ->
        chat_continue(state)

      {"handoff", _} ->
        chat_handoff(state)

      {"system", _} ->
        # Placeholder — system mode not yet implemented
        {state, []}

      _ ->
        {state, []}
    end
  end

  defp help_record do
    %Egghead.Record{
      id: "help",
      title: "Egghead TUI Help",
      body: """
      # Keybindings

      - **↑/↓** — Navigate record list
      - **Enter** — Open selected record in $EDITOR (or follow link)
      - **Tab** — Cycle through links in preview
      - **Escape** — Deselect link
      - **Backspace** — Navigate back (when search is empty)
      - **Ctrl+F** — Toggle durable-only / all record classes
      - **Ctrl+T** — Toggle date format (relative ↔ ISO 8601)
      - **Ctrl+N/Ctrl+P** — Scroll preview down/up
      - **Ctrl+J/Ctrl+K** — Scroll preview down/up
      - **PageDown/PageUp** — Scroll preview down/up
      - **/** — Enter command mode
      - **Ctrl+Q** — Quit

      # Commands

      - **/quit** — Exit the TUI
      - **/help** — Show this help
      - **/new [id]** — Create a new record and open in editor
      - **/chat** — Enter chat mode (coming soon)
      - **/system** — Agent diagnostics (coming soon)
      - **/debug** — Dump render buffer to /tmp/egghead_render.txt

      # Graph Navigation

      Use **Tab** to highlight links in the preview. Press **Enter** to
      follow a link — the preview updates to show that record. Press
      **Backspace** to go back. Links and backlinks are shown at the
      bottom of the preview.
      """,
      tags: [],
      links: [],
      class: :durable,
      updated: DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp create_and_edit_record(state) do
    # Parse optional id from command input: "new my-record-id" → "my-record-id"
    id =
      case String.split(state.command_input, " ", parts: 2) do
        [_, rest] when rest != "" -> String.trim(rest)
        _ -> "new-record-#{System.system_time(:second)}"
      end

    create_and_open(state, id, nil)
  end

  # Create a record file at the given id (if missing) and open in $EDITOR.
  # Used by both the /new command and the search-as-create phantom row.
  # When title is provided, it's written into frontmatter (and the id may
  # be a slug derived from a longer title).
  defp create_and_open(state, id, title) do
    path = Path.join([File.cwd!(), "records", "#{id}.md"])

    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))

      lines = [
        "---",
        "id: #{id}",
        title && title != id && "title: #{title}",
        "tags: []",
        "class: durable",
        "---",
        ""
      ]

      content =
        lines
        |> Enum.reject(&(&1 == false || &1 == nil))
        |> Enum.join("\n")
        |> Kernel.<>("\n")

      File.write!(path, content)
    end

    quit_for_editor(state, path)
  end

  # --- Editor ---
  #
  # Opening $EDITOR from inside a TUI requires fully shutting down the
  # Runtime first. The Erlang IO system, TermUI's InputReader, and the
  # terminal state all fight the editor if we try to run it inline.
  #
  # Pattern (same as BubbleTea's tea.ExecProcess):
  # 1. Save editor intent + restore state to Application env
  # 2. Return :quit to cleanly shut down the Runtime
  # 3. Egghead.tui_loop detects the pending editor, runs it with a
  #    fully clean terminal (Port :nouse_stdio)
  # 4. tui_loop restarts the Runtime; init restores the saved state

  defp open_in_editor(state) do
    case Enum.at(state.results, state.selected) do
      nil ->
        {state, []}

      record ->
        case Egghead.get_record(record.id) do
          {:ok, %{source_path: path}} when not is_nil(path) ->
            quit_for_editor(state, path)

          _ ->
            {state, []}
        end
    end
  end

  defp quit_for_editor(state, path) do
    editor = System.get_env("EDITOR") || "vi"

    restore = %{
      query: state.query,
      selected: state.selected,
      scroll: state.scroll_offset,
      show_all: state.show_all_classes
    }

    Application.put_env(:egghead, :pending_editor, {editor, path, restore})
    {state, [:quit]}
  end

  # --- Chat mode ---

  # Resolve or create the room, subscribe to its PubSub topic, seed the
  # transcript and presence, switch to chat mode.
  defp enter_chat_mode(state) do
    room_id =
      case Egghead.default_room() do
        nil ->
          case Egghead.create_room(default: true) do
            {:ok, id} -> id
            _ -> nil
          end

        id ->
          id
      end

    if is_nil(room_id) do
      {state, []}
    else
      try do
        Phoenix.PubSub.subscribe(Egghead.PubSub, Egghead.Chat.Room.topic(room_id))
      catch
        _, _ -> :ok
      end

      transcript = safe_chat_transcript(room_id)
      messages = Enum.flat_map(transcript, &message_to_entries/1)

      agents =
        Enum.map(state.agents, fn agent ->
          %{
            id: agent.id,
            name: agent_basename(agent.id),
            model: Map.get(agent, :model, ""),
            ctx_pct: 0,
            status: :idle
          }
        end)

      new_state =
        %{
          state
          | mode: :chat,
            chat_room_id: room_id,
            chat_messages: messages,
            chat_streams: %{},
            chat_input: "",
            chat_cursor: 0,
            chat_input_extra_lines: [],
            chat_scroll: 0,
            chat_agents: agents,
            chat_budget: nil,
            chat_ghost: nil,
            # Always start chat mode with command palette closed
            command_mode: false,
            command_input: "",
            command_selected: 0,
            command_arg: ""
        }
        |> recompute_chat_total_lines()

      {new_state, []}
    end
  end

  defp leave_chat_mode(state) do
    if state.chat_room_id do
      try do
        Phoenix.PubSub.unsubscribe(Egghead.PubSub, Egghead.Chat.Room.topic(state.chat_room_id))
      catch
        _, _ -> :ok
      end
    end

    # Reload records from the store. The TUI's `all_records` cache is
    # populated at init/1 and goes stale during a session — anything
    # written while in chat mode (e.g. /save persisting the transcript
    # as a deliberation record) won't appear in the records list
    # otherwise. Egghead.create_record upserts the index synchronously,
    # so a fresh list_records call sees the new record immediately.
    all_records =
      try do
        Egghead.list_records()
      catch
        _, _ -> state.all_records
      end

    results = filter_and_sort(all_records, state.show_all_classes, state.query)
    selected = min(state.selected, max(0, length(results) - 1))

    new_state = %{
      state
      | mode: :records,
        all_records: all_records,
        results: results,
        selected: selected,
        chat_room_id: nil,
        chat_messages: [],
        chat_streams: %{},
        chat_input: "",
        chat_cursor: 0,
        chat_input_extra_lines: [],
        chat_scroll: 0,
        chat_total_lines: 0,
        chat_agents: [],
        chat_budget: nil,
        chat_ghost: nil,
        # Drop any in-flight command mode so we don't return to records
        # with a stale command palette open.
        command_mode: false,
        command_input: "",
        command_selected: 0,
        command_arg: ""
    }

    {set_preview(new_state, preview_for_selection(new_state, selected)), []}
  end

  defp safe_chat_transcript(room_id) do
    try do
      Egghead.chat_transcript(room_id) || []
    catch
      _, _ -> []
    end
  end

  # Convert a Room.Message struct (or map) into a list of chat_entry tuples.
  # Agent messages with `\n\n` get split into multiple :message entries.
  defp message_to_entries(%{sender: %{type: :user, name: name}, content: content} = msg) do
    [
      {:message,
       %{
         nick: name,
         color: :user,
         body: content,
         usage: nil,
         ts: Map.get(msg, :timestamp)
       }}
    ]
  end

  defp message_to_entries(
         %{sender: %{type: :agent, id: agent_id, name: name}, content: content} = msg
       ) do
    nick = agent_basename(name || agent_id)

    content
    |> split_agent_blocks()
    |> Enum.map(fn block ->
      {:message,
       %{
         nick: nick,
         agent_id: agent_id,
         color: :agent,
         body: block,
         usage: Map.get(msg, :usage),
         ts: Map.get(msg, :timestamp)
       }}
    end)
  end

  defp message_to_entries(_), do: []

  # Split an agent message body on blank-line boundaries (\n\n+).
  # Each chunk becomes its own :message entry, so the agent appears to
  # speak in distinct paragraphs with separate nick prefixes.
  defp split_agent_blocks(content) when is_binary(content) do
    content
    |> String.split(~r/\n\s*\n/, trim: false)
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> [content]
      blocks -> blocks
    end
  end

  defp split_agent_blocks(_), do: []

  # Last segment of a slash-separated agent id (agents/scout → scout).
  defp agent_basename(id) when is_binary(id) do
    case String.split(id, "/") do
      [] -> id
      parts -> List.last(parts)
    end
  end

  defp agent_basename(_), do: ""

  # Schedule a single :chat_anim_tick if one isn't already pending and
  # there's at least one active stream. Idempotent — call this from any
  # path that may have introduced a new stream.
  defp maybe_start_animation_tick(state) do
    if state.chat_anim_pending or map_size(state.chat_streams) == 0 do
      state
    else
      schedule_chat_anim_tick(state)
    end
  end

  defp schedule_chat_anim_tick(state) do
    Process.send_after(self(), :chat_anim_tick, 350)
    %{state | chat_anim_pending: true}
  end

  defp recompute_chat_total_lines(state) do
    width = max(20, state.width)
    lines = Egghead.TUI.ChatRender.render_entries(chat_display_entries(state), width)
    %{state | chat_total_lines: length(lines)}
  end

  # Combine committed messages + in-progress streams in display order
  # (in-progress entries appear at the bottom). Each stream becomes
  # either a :thinking action (no committed paragraphs yet) or an
  # :in_progress message (committed paragraphs + a streaming cursor).
  defp chat_display_entries(state) do
    frame = state.chat_anim_frame

    streaming_entries =
      state.chat_streams
      |> Enum.sort_by(fn {_, %{started_at: t}} -> t end)
      |> Enum.map(fn {agent_id, %{name: name, committed: committed}} ->
        nick = agent_basename(name || agent_id)

        if committed == "" do
          {:thinking, %{nick: nick, agent_id: agent_id, frame: frame}}
        else
          {:in_progress, %{nick: nick, agent_id: agent_id, body: committed}}
        end
      end)

    state.chat_messages ++ streaming_entries
  end

  # Stub command handlers — full implementations come in the slash
  # commands step. For now they just append a system entry so the user
  # gets feedback that the command was received.
  defp chat_save(state) do
    case state.chat_room_id do
      nil ->
        {state, []}

      room_id ->
        msg =
          case Egghead.chat_save(room_id) do
            {:ok, id} -> "saved → #{id}"
            {:error, reason} -> "save failed: #{inspect(reason)}"
          end

        {append_system(state, msg, :info), []}
    end
  end

  defp chat_continue(state) do
    case state.chat_room_id do
      nil ->
        {state, []}

      room_id ->
        try do
          Egghead.chat_continue(room_id)
        catch
          _, _ -> :ok
        end

        {append_system(state, "budget reset", :info), []}
    end
  end

  defp chat_handoff(state) do
    arg = String.trim(state.command_arg || "")

    if arg == "" do
      {append_system(state, "/handoff requires an agent id (e.g. /handoff scout)", :warning),
       []}
    else
      target =
        if String.contains?(arg, "/"),
          do: arg,
          else: "agents/" <> arg

      result =
        try do
          Egghead.handoff(target, "")
        catch
          _, reason -> {:error, reason}
        end

      msg =
        case result do
          {:ok, delib_id} -> "#{arg} handed off → #{delib_id}"
          {:error, reason} -> "handoff failed: #{inspect(reason)}"
          _ -> "handoff requested for #{arg}"
        end

      {append_system(state, msg, :info), []}
    end
  end

  defp append_system(state, text, kind) do
    entry = {:system, %{text: text, kind: kind, ts: DateTime.utc_now()}}

    %{state | chat_messages: state.chat_messages ++ [entry]}
    |> recompute_chat_total_lines()
  end

  # Concatenate the multi-line input and ship it. Clears the input on
  # success. The chat happens on a background task so we don't block the
  # update loop on the LLM call (the room broadcasts back via PubSub).
  defp chat_send(state) do
    text =
      (state.chat_input_extra_lines ++ [state.chat_input])
      |> Enum.join("\n")
      |> String.trim()

    if text == "" or is_nil(state.chat_room_id) do
      {state, []}
    else
      room_id = state.chat_room_id

      Task.start(fn ->
        try do
          Egghead.chat(room_id, text)
        catch
          _, _ -> :ok
        end
      end)

      new_state = %{
        state
        | chat_input: "",
          chat_cursor: 0,
          chat_input_extra_lines: [],
          chat_ghost: nil,
          chat_scroll: 0
      }

      {new_state, []}
    end
  end

  # Recompute the ghost-text completion: if the input ends with `@<prefix>`,
  # find the first agent whose basename starts with prefix (case-insensitive)
  # and store the missing suffix as ghost.
  defp refresh_chat_ghost(state) do
    case extract_mention_prefix(state.chat_input) do
      nil ->
        %{state | chat_ghost: nil}

      "" ->
        %{state | chat_ghost: nil}

      prefix ->
        suffix = find_mention_completion(state.chat_agents, prefix)
        %{state | chat_ghost: suffix}
    end
  end

  # Returns the prefix after the LAST `@` in the input, if it's followed
  # only by alnum/`-`/`_`/`/` chars and no whitespace. Public for testing.
  @doc false
  def extract_mention_prefix(input) when is_binary(input) do
    case Regex.run(~r/@([\w\/\-]*)$/, input) do
      [_, prefix] -> prefix
      _ -> nil
    end
  end

  @doc false
  def find_mention_completion([], _prefix), do: nil

  def find_mention_completion(agents, prefix) do
    p = String.downcase(prefix)

    agents
    |> Enum.find(fn agent ->
      base = String.downcase(agent.name || agent_basename(agent.id))
      String.starts_with?(base, p) and base != p
    end)
    |> case do
      nil ->
        nil

      agent ->
        base = agent.name || agent_basename(agent.id)
        # Suffix to append to the prefix to complete the mention
        String.slice(base, String.length(prefix)..-1//1)
    end
  end

  defp compute_chat_max_scroll(state) do
    h = max(1, state.height - 4 - input_box_height(state))
    max(0, state.chat_total_lines - h)
  end

  # --- Stdin drain ---

  # Drain stale bytes from the Erlang IO system. Spawns a process that
  # reads via IO.getn (which goes through OTP's prim_tty) until no more
  # data is available. The 200ms timeout handles the case where there's
  # nothing to drain — IO.getn blocks in raw mode when stdin is empty.
  defp drain_stale_input do
    parent = self()

    drainer =
      spawn(fn ->
        drain_io_loop()
        send(parent, :drain_done)
      end)

    receive do
      :drain_done -> :ok
    after
      200 ->
        Process.exit(drainer, :kill)
        :ok
    end
  end

  defp drain_io_loop do
    case IO.getn("", 1) do
      data when is_binary(data) and byte_size(data) > 0 ->
        drain_io_loop()

      _ ->
        :ok
    end
  end

  # --- Helpers ---

  defp list_height(state) do
    body = max(1, state.height - 5)
    max(1, div(body, 3))
  end

  defp adjust_scroll(selected, scroll, visible_h) do
    cond do
      selected < scroll -> selected
      selected >= scroll + visible_h -> selected - visible_h + 1
      true -> scroll
    end
  end

  defp format_time(updated, :relative), do: relative_time(updated)
  defp format_time(updated, :iso), do: iso_date(updated)

  defp relative_time(nil), do: ""

  defp relative_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :second)

        cond do
          diff < 60 -> "#{diff}s"
          diff < 3600 -> "#{div(diff, 60)}m"
          diff < 86400 -> "#{div(diff, 3600)}h"
          diff < 604_800 -> "#{div(diff, 86400)}d"
          true -> "#{div(diff, 604_800)}w"
        end

      _ ->
        ""
    end
  end

  defp relative_time(_), do: ""

  defp iso_date(nil), do: ""

  defp iso_date(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d")
      _ -> ""
    end
  end

  defp iso_date(_), do: ""
end
