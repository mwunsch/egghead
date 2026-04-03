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

    # Default: show only durable records, sorted by updated desc
    durable = filter_and_sort(all_records, false)
    preview = load_preview(durable, 0)

    %State{
      width: w,
      height: h,
      all_records: all_records,
      results: durable,
      agents: agents,
      preview: preview
    }
  end

  # --- handle_info for PubSub and async messages ---

  def handle_info({:terminal_resize, {rows, cols}}, state) do
    {%{state | width: cols, height: rows}, []}
  end

  def handle_info(_msg, state), do: state

  # --- Event handling ---

  @impl true
  # Ctrl+C handled by +Bd flag (BEAM exits cleanly, no break menu).
  # Ctrl+Q as in-app quit for when running without +Bd (e.g. mix egghead.tui)
  def event_to_msg(%Event.Key{key: "q", modifiers: [:ctrl]}, _state), do: {:msg, :quit}

  def event_to_msg(%Event.Key{key: :escape}, %{command_mode: true}) do
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
        preview = load_preview(state.results, new_sel)

        {%{state | selected: new_sel, scroll_offset: scroll, preview: preview, preview_scroll: 0},
         []}

      :move_down ->
        max_sel = max(0, length(state.results) - 1)
        new_sel = min(max_sel, state.selected + 1)
        scroll = adjust_scroll(new_sel, state.scroll_offset, list_height(state))
        preview = load_preview(state.results, new_sel)

        {%{state | selected: new_sel, scroll_offset: scroll, preview: preview, preview_scroll: 0},
         []}

      :preview_scroll_down ->
        {%{state | preview_scroll: state.preview_scroll + 5}, []}

      :preview_scroll_up ->
        {%{state | preview_scroll: max(0, state.preview_scroll - 5)}, []}

      :toggle_filter ->
        show_all = not state.show_all_classes
        results = filter_and_sort(state.all_records, show_all, state.query)
        preview = load_preview(results, 0)

        {%{
           state
           | show_all_classes: show_all,
             results: results,
             selected: 0,
             scroll_offset: 0,
             preview: preview
         }, []}

      :open_editor ->
        open_in_editor(state)

      # Command mode
      :enter_command ->
        {%{state | command_mode: true, command_input: "", command_selected: 0}, []}

      :exit_command ->
        {%{state | command_mode: false, command_input: ""}, []}

      {:command_char, c} ->
        {%{state | command_input: state.command_input <> c, command_selected: 0}, []}

      :command_backspace ->
        input = String.slice(state.command_input, 0..-2//1)
        {%{state | command_input: input, command_selected: 0}, []}

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
    body = max(1, h - 5)
    list_h = max(1, div(body, 3))
    preview_h = max(1, body - list_h)

    lines =
      [render_header(state, w)] ++
        [render_search(state, w)] ++
        render_list(state, w, list_h) ++
        [text("", nil)] ++
        render_preview(state, w, preview_h) ++
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

    # Layout: " Title                                          time "
    right = " #{time} "
    right_len = String.length(right)
    title_max = max(1, w - right_len - 2)
    title_str = String.pad_trailing(String.slice(title, 0, title_max), title_max)
    line = " " <> title_str <> right

    if selected do
      text(line, Theme.selected())
    else
      text(line, Theme.normal())
    end
  end

  # --- Preview ---

  defp render_preview(%{preview: nil}, w, preview_h) do
    label = render_preview_label("(no selection)", "", w)
    [label | List.duplicate(text("", nil), max(0, preview_h - 1))]
  end

  defp render_preview(%{preview: record, preview_scroll: scroll}, w, preview_h) do
    body = record.body || "(no content)"
    total_lines = Egghead.TUI.Markdown.render(body, w - 4)
    total_count = length(total_lines)

    # Reserve lines for links and scroll indicator
    links_lines = render_links(record, w)
    content_h = max(0, preview_h - 1 - length(links_lines))

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

        line =
          (" " <> content)
          |> String.slice(0, w - 1)
          |> String.pad_trailing(w - 1)

        scrollbar_char = if is_thumb, do: "▐", else: " "
        text(line <> scrollbar_char, style)
      end)

    padding = List.duplicate(text("", nil), max(0, content_h - length(visible)))
    [label] ++ visible ++ padding ++ links_lines
  end

  defp render_preview_label(name, scroll_info, w) do
    label = " ── preview: #{name}#{scroll_info} "
    pad = max(0, w - String.length(label))
    text(label <> String.duplicate("─", pad), Theme.separator())
  end

  defp render_links(record, w) do
    if record.links != [] do
      link_text = Enum.map_join(record.links, "  ", &"[[#{&1}]]")
      [text(" Links: " <> String.slice(link_text, 0, w - 10), Theme.link())]
    else
      []
    end
  end

  # --- Status bar (dark background band) ---

  defp render_status(_state, w) do
    left = " REC │ ↑↓ nav │ ^n/^p scroll │ ⏎ $EDITOR │ / cmd │ tab filter │ ^c quit"
    pad = max(0, w - String.length(left))
    text(left <> String.duplicate(" ", pad), Theme.status_bar_line())
  end

  # --- Key routing ---

  defp records_event(event, _state) do
    case event.key do
      :up ->
        {:msg, :move_up}

      :down ->
        {:msg, :move_down}

      :enter ->
        {:msg, :open_editor}

      :tab ->
        {:msg, :toggle_filter}

      :backspace ->
        {:msg, :backspace}

      :page_down ->
        {:msg, :preview_scroll_down}

      :page_up ->
        {:msg, :preview_scroll_up}

      _ ->
        cond do
          # Ctrl combos: key is "j"/"k", char is nil, modifiers is [:ctrl]
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
              "/" -> {:msg, :enter_command}
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
          c when is_binary(c) and c != "" -> {:msg, {:command_char, c}}
          _ -> :ignore
        end
    end
  end

  # --- Search ---

  defp search(state, query) do
    results = filter_and_sort(state.all_records, state.show_all_classes, query)
    preview = load_preview(results, 0)

    {%{state | query: query, results: results, selected: 0, scroll_offset: 0, preview: preview},
     []}
  end

  defp filter_and_sort(records, show_all, query \\ "") do
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
          String.contains?(String.downcase(r.id), q) or
            (r.title && String.contains?(String.downcase(r.title), q)) or
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

  # --- Commands ---

  @commands [
    {"quit", "Exit the TUI"},
    {"chat", "Enter chat mode"},
    {"system", "View agent diagnostics"},
    {"help", "Show help"},
    {"new", "Create a new record"}
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
      {"quit", _} -> {state, [:quit]}
      _ -> {state, []}
    end
  end

  # --- Editor ---

  defp open_in_editor(state) do
    case Enum.at(state.results, state.selected) do
      nil ->
        {state, []}

      record ->
        case Egghead.get_record(record.id) do
          {:ok, %{source_path: path}} when not is_nil(path) ->
            editor = System.get_env("EDITOR") || "vi"
            # Suspend TUI: leave alternate screen, restore terminal for editor
            TermUI.Terminal.show_cursor()
            TermUI.Terminal.leave_alternate_screen()
            TermUI.Terminal.disable_raw_mode()

            # Run editor — interactive, needs cooked mode + main screen
            System.cmd(editor, [path], into: IO.stream())

            # Resume TUI: re-enter alternate screen, raw mode
            TermUI.Terminal.enable_raw_mode()
            TermUI.Terminal.enter_alternate_screen()
            TermUI.Terminal.hide_cursor()
            # Force full screen clear to avoid artifacts
            IO.write("\e[2J")

            # Reload the record in case it was edited
            preview = load_preview(state.results, state.selected)

            all =
              try do
                Egghead.list_records()
              catch
                _, _ -> state.all_records
              end

            results = filter_and_sort(all, state.show_all_classes, state.query)
            {%{state | preview: preview, all_records: all, results: results}, []}

          _ ->
            {state, []}
        end
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
