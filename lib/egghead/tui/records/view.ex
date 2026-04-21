defmodule Egghead.TUI.Records.View do
  @moduledoc """
  Pure view function for the records-list screen.

  Takes a `Egghead.TUI.Records.Model` plus the terminal
  dimensions and returns a `Egghead.OpenTUI.View.tree`. No I/O.
  The runtime calls this on every frame; the layout engine and
  renderer turn the result into bridge calls.

  Layout (top → bottom):

      header bar              (1 row, full-width styled bar)
      search bar              (1 row, full-width styled bar)
      separator               (1 row of `─`)
      list pane               (≈⅓ of remaining body)
      blank spacer            (1 row)
      preview pane + scrollbar(≈⅔ of remaining body)
      blank spacer            (1 row)
      status bar              (1 row, full-width styled bar)

  Colors are pulled from `Egghead.OpenTUI.Colors` directly. A
  dedicated theme module is a follow-on.
  """

  import Egghead.OpenTUI.View
  alias Egghead.OpenTUI.Colors
  alias Egghead.TUI.{Records.Model, ThemePicker}

  @doc """
  Build the view tree for the given model. The model carries
  its own `width` and `height` (kept in sync by the runtime via
  `{:resize, w, h}` messages), so this function is a pure
  derivation of `model → tree`.

  The chrome (header + search + separator + 2 blanks + status)
  is 6 rows. The remaining body is split 1/3 list / 2/3 preview.
  The preview reserves one row for its label and the rest is body.
  """
  @spec render(Model.t()) :: Egghead.OpenTUI.View.tree()
  def render(%Model{} = model) do
    width = model.width
    height = model.height
    picker_h = if model.theme_picker, do: ThemePicker.height(model.theme_picker), else: 0
    body_h = max(height - 6 - picker_h, 1)
    list_h = max(div(body_h, 3), 1)
    preview_h = max(body_h - list_h, 1)
    footer_h = length(model.preview_footer)
    content_h = max(preview_h - 1 - footer_h, 1)

    picker_node =
      case model.theme_picker do
        nil -> []
        picker -> [ThemePicker.view(picker, width)]
      end

    # Records mode's input/filter sits near the top (header → search
    # → separator), so the picker drops under the search field like
    # a real autocomplete. In chat mode the input is near the
    # bottom and the picker lives above the status bar; see
    # `Egghead.TUI.Chat.View.render/1`.
    vbox(
      [header(model, width), search(model, width)] ++
        picker_node ++
        [
          separator(width),
          list_pane(model, width, list_h),
          blank(width),
          preview_pane(model, width, preview_h, content_h),
          blank(width),
          status_bar(model, width)
        ]
    )
  end

  # ---- panes --------------------------------------------------------------

  defp header(model, width) do
    count = length(model.filtered)
    filter_label = if model.show_all_classes, do: "all", else: "durable"
    context = "#{filter_label} · #{count} records"

    Egghead.TUI.Header.render(:records, context, width, model.providers?)
  end

  defp search(%Model{command_mode: true} = model, _width) do
    # Command-mode prompt: " /input" with the terminal cursor
    # placed at `command_cursor` via the `:cursor` view leaf,
    # same trick as the filter bar. Supports full readline
    # editing (Ctrl+A/E/K/U/W, Alt+B/F/D, ←/→).
    prompt = " /"
    cursor_idx = model.command_cursor
    prefix = String.slice(model.command_input, 0, cursor_idx)

    suffix =
      String.slice(
        model.command_input,
        cursor_idx,
        String.length(model.command_input)
      )

    fg = Colors.accent()
    bg = Colors.bg()

    prompt_w = String.length(prompt)
    prefix_w = String.length(prefix)
    suffix_w = String.length(suffix)

    hbox(
      [height: 1],
      [
        text(prompt <> prefix,
          width: prompt_w + prefix_w,
          fg: fg,
          bg: bg
        ),
        cursor(),
        text(suffix,
          width: suffix_w,
          fg: fg,
          bg: bg
        ),
        fill(flex: 1, bg: bg)
      ]
    )
  end

  defp search(model, _width) do
    # Split the filter at the cursor and emit a `cursor` leaf
    # between the two halves. The cursor leaf has zero layout
    # width, so the prefix and suffix sit flush against each
    # other; the renderer reads the cursor leaf's `(x, y)` and
    # places the terminal's text cursor there.
    cursor_idx = model.filter_cursor
    prompt = " ❯ "
    prefix = String.slice(model.filter, 0, cursor_idx)
    suffix = String.slice(model.filter, cursor_idx, String.length(model.filter))

    fg = Colors.cyan()
    bg = Colors.bg()

    prompt_w = String.length(prompt)
    prefix_w = String.length(prefix)
    suffix_w = String.length(suffix)

    hbox(
      [height: 1],
      [
        text(prompt <> prefix,
          width: prompt_w + prefix_w,
          fg: fg,
          bg: bg
        ),
        cursor(),
        text(suffix,
          width: suffix_w,
          fg: fg,
          bg: bg
        ),
        fill(flex: 1, bg: bg)
      ]
    )
  end

  defp separator(width) do
    text(String.duplicate("─", width),
      height: 1,
      fg: Colors.dim(),
      bg: Colors.bg()
    )
  end

  defp blank(width) do
    text(String.duplicate(" ", width),
      height: 1,
      fg: Colors.white(),
      bg: Colors.bg()
    )
  end

  defp list_pane(%Model{command_mode: true} = model, width, list_h) do
    command_dropdown(model, width, list_h)
  end

  defp list_pane(model, width, list_h) do
    # Scroll the visible window so the selected row stays visible.
    offset = list_scroll_offset(model.selection, list_h)

    record_rows =
      model.filtered
      |> Enum.drop(offset)
      |> Enum.take(list_h)
      |> Enum.with_index(offset)
      |> Enum.map(fn {record, idx} ->
        list_row(record, idx == model.selection, model.date_format, width)
      end)

    # Phantom create row appears at length(filtered), only when
    # there's still room in the visible window.
    phantom_rows =
      case Model.creation_target(model) do
        nil ->
          []

        {title, slug} ->
          if length(record_rows) < list_h do
            [phantom_row(title, slug, Model.phantom_selected?(model), width)]
          else
            []
          end
      end

    vbox([height: list_h], record_rows ++ phantom_rows)
  end

  # Replace the records list with a filtered list of commands.
  # The dropdown row format is `  /name — description` with the
  # selected row reverse-video. Empty list shows a muted hint.
  defp command_dropdown(model, width, list_h) do
    commands = Model.filtered_commands(model)

    rows =
      case commands do
        [] ->
          [command_empty_row(width)]

        cmds ->
          cmds
          |> Enum.with_index()
          |> Enum.take(list_h)
          |> Enum.map(fn {cmd, idx} ->
            command_row(cmd, idx == model.command_selected, width)
          end)
      end

    vbox([height: list_h], rows)
  end

  defp command_row(cmd, selected, width) do
    label = "  /#{cmd.name}"
    desc = " — #{cmd.description}"
    line = label <> desc
    pad = max(width - String.length(line), 0)
    padded = line <> String.duplicate(" ", pad)

    if selected do
      text(truncate(padded, width),
        height: 1,
        fg: Colors.white(),
        bg: Colors.selected_bg()
      )
    else
      hbox(
        [height: 1],
        [
          text(label,
            width: String.length(label),
            fg: Colors.accent(),
            bg: Colors.bg()
          ),
          text(desc,
            width: String.length(desc),
            fg: Colors.muted(),
            bg: Colors.bg()
          ),
          text(String.duplicate(" ", pad),
            width: pad,
            fg: Colors.white(),
            bg: Colors.bg()
          )
        ]
      )
    end
  end

  defp command_empty_row(width) do
    line = "  (no matching commands)"
    pad = max(width - String.length(line), 0)

    text(line <> String.duplicate(" ", pad),
      height: 1,
      fg: Colors.muted(),
      bg: Colors.bg()
    )
  end

  defp phantom_row(title, slug, selected, width) do
    label =
      if title == slug do
        " + Create \"#{title}\""
      else
        " + Create \"#{title}\"  → #{slug}"
      end

    pad = max(width - String.length(label), 0)
    line = label <> String.duplicate(" ", pad)

    fg = if selected, do: Colors.white(), else: Colors.accent()
    bg = if selected, do: Colors.selected_bg(), else: Colors.bg()

    text(truncate(line, width), height: 1, fg: fg, bg: bg)
  end

  defp list_scroll_offset(selection, list_h) when list_h > 0 do
    cond do
      selection < list_h - 2 -> 0
      true -> selection - (list_h - 3)
    end
  end

  defp list_scroll_offset(_selection, _list_h), do: 0

  defp list_row(record, selected, date_format, width) do
    title = record.title || record.id || ""
    time = format_time(record.updated, date_format)
    time_str = " " <> time <> " "
    title_max = max(width - String.length(time_str) - 2, 1)
    title_str = String.pad_trailing(slice(title, title_max), title_max)

    line = " " <> title_str <> time_str

    if selected do
      text(truncate(line, width),
        height: 1,
        fg: Colors.white(),
        bg: Colors.selected_bg()
      )
    else
      # Two-segment hbox so the date column gets its own muted
      # style without affecting the title styling.
      hbox(
        [height: 1],
        [
          text(" " <> title_str,
            width: 1 + String.length(title_str),
            fg: Colors.white(),
            bg: Colors.bg()
          ),
          text(time_str,
            width: String.length(time_str),
            fg: Colors.muted(),
            bg: Colors.bg()
          )
        ]
      )
    end
  end

  defp preview_pane(model, width, preview_h, content_h) do
    case model.selected_id do
      nil ->
        vbox(
          [height: preview_h],
          [preview_label([{"(no selection)", :muted}], width)]
        )

      id ->
        rendered = model.preview_rendered || []
        total_count = length(rendered)

        # Clamp scroll against the actual visible window so we
        # never overscroll into a blank pane.
        max_scroll = max(0, total_count - content_h)
        scroll = min(model.preview_scroll, max_scroll)

        scroll_segment =
          if total_count > content_h do
            pos =
              if max_scroll > 0,
                do: round(scroll / max_scroll * 100),
                else: 0

            "#{scroll + 1}-#{min(scroll + content_h, total_count)}/#{total_count} (#{pos}%)"
          else
            "#{total_count}L"
          end

        record_class = preview_class(model)

        label =
          preview_label(
            [{id, :normal}, {record_class, :muted}, {scroll_segment, :muted}],
            width
          )

        # Proportional scrollbar thumb. Mirrors main's render_preview/3:
        #   bar_size  = round(content_h^2 / total_count), at least 1
        #   travel    = content_h - bar_size
        #   bar_start = round(scroll / max_scroll * travel)
        {bar_start, bar_size} =
          if total_count > content_h do
            size = max(1, round(content_h * content_h / total_count))
            travel = max(0, content_h - size)
            start_pos = if max_scroll > 0, do: round(scroll / max_scroll * travel), else: 0
            {start_pos, size}
          else
            {0, 0}
          end

        # Width budgeting for each rendered row:
        #   1 col leading pad + (width - 2) cols of prose + 1 col scrollbar
        # The markdown renderer was already called with `width - 2`
        # in `Model.recompute_preview/1`, so spans never exceed it.
        text_w = max(width - 2, 1)

        active_target =
          case Model.active_link(model) do
            %{target: t} -> t
            _ -> nil
          end

        body_rows =
          rendered
          |> Enum.drop(scroll)
          |> Enum.take(content_h)
          |> Enum.with_index()
          |> Enum.map(fn {row, idx} ->
            is_thumb = bar_size > 0 and idx >= bar_start and idx < bar_start + bar_size
            scrollbar_char = if is_thumb, do: "▐", else: " "
            render_preview_row(row, text_w, scrollbar_char, active_target)
          end)

        # Metadata footer (Links / Backlinks). Pinned at the
        # bottom of the preview pane, doesn't scroll with body.
        # Rendered at full preview width (not text_w) so it can
        # use the scrollbar column for content.
        footer_rows =
          model.preview_footer
          |> Enum.map(fn row ->
            render_footer_row(row, max(width - 1, 1), active_target)
          end)

        vbox([height: preview_h], [label | body_rows] ++ footer_rows)
    end
  end

  # Footer rows have no scrollbar column. Layout: " " + spans
  # (padded to text_w). Active link spans get the same reverse-
  # video highlight treatment as body rows.
  defp render_footer_row(row, text_w, active_target) do
    span_leaves =
      Enum.map(row, fn span ->
        active? = active_target != nil and span.link == {:wikilink, active_target}

        bg = if active?, do: Colors.selected_bg(), else: Colors.bg()
        fg = if active?, do: Colors.white(), else: span.fg || Colors.white()

        text(span.text,
          width: String.length(span.text),
          fg: fg,
          bg: bg,
          attrs: span.attrs
        )
      end)

    used = Enum.reduce(row, 0, fn span, acc -> acc + String.length(span.text) end)
    pad_w = max(text_w - used, 0)

    pad_leaf =
      text(String.duplicate(" ", pad_w),
        width: pad_w,
        fg: Colors.white(),
        bg: Colors.bg()
      )

    leading =
      text(" ",
        width: 1,
        fg: Colors.white(),
        bg: Colors.bg()
      )

    hbox([height: 1], [leading | span_leaves] ++ [pad_leaf])
  end

  # Build a single preview row from a list of markdown spans.
  # Layout: " " + spans (padded to text_w) + scrollbar char.
  # Spans whose link target matches `active_target` get a
  # reverse-video background as the link-mode highlight.
  defp render_preview_row(row, text_w, scrollbar_char, active_target) do
    span_leaves =
      Enum.map(row, fn span ->
        active? = active_target != nil and span.link == {:wikilink, active_target}

        bg = if active?, do: Colors.selected_bg(), else: Colors.bg()
        fg = if active?, do: Colors.white(), else: span.fg || Colors.white()

        text(span.text,
          width: String.length(span.text),
          fg: fg,
          bg: bg,
          attrs: span.attrs
        )
      end)

    used = Enum.reduce(row, 0, fn span, acc -> acc + String.length(span.text) end)
    pad_w = max(text_w - used, 0)

    pad_leaf =
      text(String.duplicate(" ", pad_w),
        width: pad_w,
        fg: Colors.white(),
        bg: Colors.bg()
      )

    leading =
      text(" ",
        width: 1,
        fg: Colors.white(),
        bg: Colors.bg()
      )

    scrollbar =
      text(scrollbar_char,
        width: 1,
        fg: Colors.dim(),
        bg: Colors.bg()
      )

    hbox([height: 1], [leading | span_leaves] ++ [pad_leaf, scrollbar])
  end

  defp preview_class(%Model{selected_id: nil}), do: ""

  # Read the class from `selected_record` (the cached full
  # record), not `filtered[selection]`. That way synthetic
  # records like the in-memory `/help` (class `:synthetic`)
  # show the right label even though they're not in `filtered`.
  defp preview_class(%Model{selected_record: %{class: class}}),
    do: to_string(class)

  defp preview_class(_), do: ""

  # Render a preview label as " ── seg1 ── seg2 ── seg3 ─────... "
  # `segments` is `[{text, :normal | :muted}]`.
  defp preview_label(segments, width) do
    sep = " ── "

    {pieces, used} =
      segments
      |> Enum.with_index()
      |> Enum.reduce({[], 0}, fn {{txt, kind}, idx}, {acc, used} ->
        prefix = if idx == 0, do: " ── ", else: sep
        style_fg = if kind == :normal, do: Colors.white(), else: Colors.dim()

        prefix_node =
          text(prefix,
            width: String.length(prefix),
            fg: Colors.dim(),
            bg: Colors.bg()
          )

        text_node =
          text(txt,
            width: String.length(txt),
            fg: style_fg,
            bg: Colors.bg()
          )

        {acc ++ [prefix_node, text_node], used + String.length(prefix) + String.length(txt)}
      end)

    pad_count = max(width - used - 1, 0)

    tail =
      text(" " <> String.duplicate("─", pad_count),
        width: 1 + pad_count,
        fg: Colors.dim(),
        bg: Colors.bg()
      )

    hbox([height: 1], pieces ++ [tail])
  end

  defp status_bar(model, width) do
    nav_hint = if model.nav_history != [], do: " │ ⌫ back", else: ""

    line =
      cond do
        model.command_mode ->
          " CMD │ ↑↓ select │ ⏎ execute │ esc cancel │ ^q quit"

        Model.link_mode?(model) ->
          " LINK │ tab/⇧tab cycle │ ⏎ follow │ esc deselect" <> nav_hint <> " │ ^q quit"

        Model.phantom_selected?(model) ->
          " NEW │ ⏎ create │ ↑ back to results │ ^q quit"

        true ->
          " REC │ ↑↓ │ ⏎ edit │ tab links │ / cmd │ ^f filter │ ^t date" <>
            nav_hint <> " │ ^q quit"
      end

    pad_size = max(width - String.length(line), 0)
    padded = line <> String.duplicate(" ", pad_size)

    text(truncate(padded, width),
      height: 1,
      fg: Colors.white(),
      bg: Colors.selected_bg()
    )
  end

  # ---- date formatters (mirror main's relative_time/iso_date) -------------

  defp format_time(nil, _), do: ""

  defp format_time(s, :relative) when is_binary(s) do
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

  defp format_time(s, :iso) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d")
      _ -> ""
    end
  end

  # ---- string helpers ------------------------------------------------------

  defp slice(str, max) when is_binary(str) and is_integer(max) and max > 0 do
    if String.length(str) <= max, do: str, else: String.slice(str, 0, max)
  end

  defp slice(_str, _max), do: ""

  defp truncate(str, max), do: slice(str, max)
end
