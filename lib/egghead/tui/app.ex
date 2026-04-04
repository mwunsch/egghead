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

    set_preview(base, load_preview(results, selected))
  end

  # --- handle_info for PubSub and async messages ---

  def handle_info({:terminal_resize, {rows, cols}}, state) do
    {%{state | width: cols, height: rows}, []}
  end

  def handle_info(_msg, state), do: state

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

        {set_preview(
           %{state | selected: new_sel, scroll_offset: scroll},
           load_preview(state.results, new_sel)
         ), []}

      :move_down ->
        max_sel = max(0, length(state.results) - 1)
        new_sel = min(max_sel, state.selected + 1)
        scroll = adjust_scroll(new_sel, state.scroll_offset, list_height(state))

        {set_preview(
           %{state | selected: new_sel, scroll_offset: scroll},
           load_preview(state.results, new_sel)
         ), []}

      :preview_scroll_down ->
        {%{state | preview_scroll: state.preview_scroll + 5}, []}

      :preview_scroll_up ->
        {%{state | preview_scroll: max(0, state.preview_scroll - 5)}, []}

      :toggle_filter ->
        show_all = not state.show_all_classes
        results = filter_and_sort(state.all_records, show_all, state.query)

        {set_preview(
           %{state | show_all_classes: show_all, results: results, selected: 0, scroll_offset: 0},
           load_preview(results, 0)
         ), []}

      :open_editor ->
        open_in_editor(state)

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

            {%{state | link_index: idx}, []}
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
        cmds = filtered_commands(state.command_input)
        max_i = max(0, length(cmds) - 1)
        {%{state | command_selected: min(max_i, state.command_selected + 1)}, []}

      :command_execute ->
        execute_command(state)

      _ ->
        {state, []}
    end
  end

  # --- View ---

  @impl true
  def view(state) do
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
    cmds = filtered_commands(state.command_input)
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

    rows =
      Enum.map(visible, fn {record, idx} ->
        render_list_row(record, idx == state.selected, w)
      end)

    padding = List.duplicate(text("", nil), max(0, list_h - length(rows)))
    rows ++ padding
  end

  defp render_list_row(record, selected, w) do
    title = record.title || record.id
    time = relative_time(record.updated)
    time_str = " #{time} "
    title_max = max(1, w - String.length(time_str) - 2)
    title_str = String.pad_trailing(String.slice(title, 0, title_max), title_max)

    if selected do
      # Selected: entire row one style
      text(" " <> title_str <> time_str, Theme.selected())
    else
      # Normal: title white, time muted
      stack(:horizontal, [
        text(" " <> title_str, Theme.normal()),
        text(time_str, Theme.muted())
      ])
    end
  end

  # --- Preview ---

  defp render_preview(%{preview: nil}, w, preview_h) do
    label = render_preview_label("(no selection)", "", w)
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

    # Scroll position indicator in the label
    scroll_info =
      if total_count > content_h do
        pos = if max_scroll > 0, do: round(scroll / max_scroll * 100), else: 0
        " #{scroll + 1}-#{min(scroll + content_h, total_count)}/#{total_count} (#{pos}%)"
      else
        ""
      end

    label = render_preview_label(record.id, scroll_info, w)

    # Render visible lines — each exactly w characters, with scrollbar on right edge
    visible =
      total_lines
      |> Enum.drop(scroll)
      |> Enum.take(content_h)
      |> Enum.with_index()
      |> Enum.map(fn {{content, style}, idx} ->
        is_thumb =
          if total_count > content_h do
            bar_start =
              if max_scroll > 0, do: round(scroll / max_scroll * (content_h - 1)), else: 0

            bar_size = max(1, round(content_h / total_count * content_h))
            idx >= bar_start and idx < bar_start + bar_size
          else
            false
          end

        # Content padded to fixed width, scrollbar as separate styled node.
        # The diff merges adjacent spans (gap=0) but preserves style groups,
        # so the scrollbar style is emitted correctly.
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

  defp render_preview_label(name, scroll_info, w) do
    label = " ── preview: #{name}#{scroll_info} "
    pad = max(0, w - String.length(label))
    text(label <> String.duplicate("─", pad), Theme.separator())
  end

  defp render_links(%{preview_links: []}, _w), do: []

  defp render_links(%{preview_links: links, link_index: link_index}, w) do
    {fwd, back} = Enum.split_with(links, fn {_, _, type} -> type == :forward end)

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

        true ->
          " REC │ ↑↓ nav │ ^n/^p scroll │ ⏎ $EDITOR │ / cmd │ tab links │ ^f filter │ ^q quit"
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

    {set_preview(
       %{state | query: query, results: results, selected: 0, scroll_offset: 0},
       load_preview(results, 0)
     ), []}
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

  # Set preview and compute navigable links (forward + backlinks).
  # Resets link_index and preview_scroll for a clean slate.
  defp set_preview(state, preview) do
    links = collect_preview_links(preview)
    %{state | preview: preview, preview_scroll: 0, link_index: nil, preview_links: links}
  end

  defp collect_preview_links(nil), do: []

  defp collect_preview_links(record) do
    forward = Enum.map(record.links || [], fn id -> {id, id, :forward} end)

    backlinks =
      try do
        Egghead.find_backlinks(record.id)
        |> Enum.map(fn r -> {r.id, r.title || r.id, :backlink} end)
      catch
        _, _ -> []
      end

    forward_ids = MapSet.new(record.links || [])

    filtered_back =
      Enum.reject(backlinks, fn {id, _, _} ->
        id == record.id || MapSet.member?(forward_ids, id)
      end)

    (forward ++ filtered_back) |> Enum.uniq_by(fn {id, _, _} -> id end)
  end

  # --- Commands ---

  @commands [
    {"quit", "Exit the TUI"},
    {"help", "Show keybindings & commands"},
    {"new", "Create a new record"},
    {"chat", "Enter chat mode"},
    {"system", "Agent diagnostics"},
    {"debug", "Dump buffer to /tmp/egghead_render.txt"}
  ]

  defp filtered_commands(input) do
    q = String.downcase(input)
    Enum.filter(@commands, fn {name, _} -> String.starts_with?(name, q) end)
  end

  defp execute_command(state) do
    cmds = filtered_commands(state.command_input)
    selected = Enum.at(cmds, state.command_selected)

    state = %{state | command_mode: false, command_input: ""}

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
        # Placeholder — chat mode not yet implemented
        {state, []}

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

    path = Path.join([File.cwd!(), "records", "#{id}.md"])

    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))

      File.write!(path, """
      ---
      id: #{id}
      tags: []
      class: durable
      ---

      """)
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
end
