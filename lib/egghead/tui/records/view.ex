defmodule Egghead.TUI.Records.View do
  @moduledoc """
  Pure view function for the records-list screen.

  Takes a `Egghead.TUI.Records.Model` plus the terminal dimensions
  and returns a `Egghead.OpenTUI.View.tree`. No I/O. The
  runtime calls this on every frame; the layout engine and
  renderer turn the result into bridge calls.

  Phase 5b additions over 5a:

    * Header includes class filter state (`durable` / `all`) and
      both record counts.
    * Date column respects `model.date_format` (relative or ISO).
    * Preview pane slices its body by `model.preview_scroll`.
    * Status bar shows the full key hint set.
  """

  import Egghead.OpenTUI.View
  alias Egghead.OpenTUI.Colors
  alias Egghead.TUI.Records.Model

  @doc """
  Build the view tree for the given model. Width/height are
  passed in so list and preview panes can compute scroll
  offsets and truncation widths.
  """
  @spec render(Model.t(), pos_integer(), pos_integer()) :: Egghead.OpenTUI.View.tree()
  def render(%Model{} = model, width, _height) do
    vbox([
      header(model, width),
      search(model, width),
      list_pane(model, width),
      divider(width),
      preview_pane(model, width),
      status_bar(width)
    ])
  end

  # ---- panes --------------------------------------------------------------

  defp header(model, width) do
    class_label = if model.show_all_classes, do: "all", else: "durable"

    label =
      "egghead — #{class_label} · #{length(model.all)} records · " <>
        "#{length(model.filtered)} shown"

    text(truncate(label, width),
      height: 1,
      fg: Colors.white(),
      bg: Colors.bg()
    )
  end

  defp search(model, width) do
    label = "❯ " <> model.filter <> "_"

    text(truncate(label, width),
      height: 1,
      fg: Colors.cyan(),
      bg: Colors.bg()
    )
  end

  defp list_pane(model, width) do
    rows =
      model.filtered
      |> Enum.with_index()
      |> Enum.map(fn {record, idx} ->
        list_row(record, idx, model.selection, model.date_format, width)
      end)

    vbox([flex: 1], rows)
  end

  defp list_row(record, idx, selection, date_format, width) do
    is_selected = idx == selection
    label = record.id || ""
    time_str = format_time(record.updated, date_format)

    time_w = String.length(time_str)
    label_w = max(width - time_w - 2, 0)

    line =
      " " <>
        String.pad_trailing(truncate(label, label_w), label_w) <>
        " " <>
        time_str

    line = truncate(line, width)

    if is_selected do
      text(line, height: 1, fg: Colors.white(), bg: Colors.dim())
    else
      text(line, height: 1, fg: Colors.white(), bg: Colors.bg())
    end
  end

  defp divider(width) do
    text(String.duplicate("─", width),
      height: 1,
      fg: Colors.dim(),
      bg: Colors.bg()
    )
  end

  defp preview_pane(model, width) do
    case model.selected_id do
      nil ->
        vbox(
          [flex: 2],
          [text("(no selection)", height: 1, fg: Colors.dim(), bg: Colors.bg())]
        )

      id ->
        scroll_label =
          if model.preview_total_lines > 0 do
            "  #{model.preview_scroll + 1}/#{model.preview_total_lines}"
          else
            ""
          end

        header_line = preview_header(id, scroll_label, width)

        body_rows =
          (model.selected_body || "")
          |> String.split("\n")
          |> Enum.drop(model.preview_scroll)
          |> Enum.map(fn line ->
            text(truncate(line, width),
              height: 1,
              fg: Colors.white(),
              bg: Colors.bg()
            )
          end)

        vbox([flex: 2], [header_line | body_rows])
    end
  end

  defp preview_header(id, scroll_label, width) do
    base = "── #{id}#{scroll_label} "
    pad = max(width - String.length(base), 0)

    text(truncate(base <> String.duplicate("─", pad), width),
      height: 1,
      fg: Colors.dim(),
      bg: Colors.bg()
    )
  end

  defp status_bar(width) do
    label =
      " ↑↓ select · pgup/pgdn scroll · ^f class · ^t date · type filter · esc quit"

    text(truncate(label, width),
      height: 1,
      fg: Colors.white(),
      bg: Colors.dim()
    )
  end

  # ---- helpers ------------------------------------------------------------

  defp format_time(nil, _format), do: "         "

  defp format_time(s, :iso) when is_binary(s) do
    # ISO is the raw stored value, just trimmed to 19 chars (the
    # YYYY-MM-DDTHH:MM:SS prefix) to avoid runaway widths.
    String.slice(s, 0, 19)
  end

  defp format_time(s, :relative) when is_binary(s) do
    case parse_iso(s) do
      {:ok, dt} -> humanize(dt)
      _ -> String.slice(s, 0, 10)
    end
  end

  defp parse_iso(s) do
    # Records may be stored as `YYYY-MM-DDTHH:MM:SS[.fff]Z`, plain
    # NaiveDateTime, or just `YYYY-MM-DD`. Try in order.
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      _ ->
        case NaiveDateTime.from_iso8601(s) do
          {:ok, ndt} ->
            {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}

          _ ->
            case Date.from_iso8601(String.slice(s, 0, 10)) do
              {:ok, d} -> {:ok, DateTime.new!(d, ~T[00:00:00], "Etc/UTC")}
              _ -> :error
            end
        end
    end
  end

  defp humanize(%DateTime{} = dt) do
    seconds_ago = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds_ago < 60 -> "just now"
      seconds_ago < 3600 -> "#{div(seconds_ago, 60)}m ago"
      seconds_ago < 86_400 -> "#{div(seconds_ago, 3600)}h ago"
      seconds_ago < 7 * 86_400 -> "#{div(seconds_ago, 86_400)}d ago"
      seconds_ago < 30 * 86_400 -> "#{div(seconds_ago, 7 * 86_400)}w ago"
      true -> "#{div(seconds_ago, 30 * 86_400)}mo ago"
    end
  end

  defp truncate(str, max) when is_binary(str) and is_integer(max) and max > 0 do
    if String.length(str) <= max, do: str, else: String.slice(str, 0, max)
  end

  defp truncate(_str, _max), do: ""
end
