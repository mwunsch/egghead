defmodule Egghead.TUI.Records.View do
  @moduledoc """
  Pure view function for the records-list screen.

  Takes a `Egghead.TUI.Records.Model` plus the terminal dimensions
  and returns a `Egghead.OpenTUI.View.tree`. No I/O. The
  runtime calls this on every frame; the layout engine and
  renderer turn the result into bridge calls.

  Phase 5a renders the same six panes as the Phase 4 imperative
  implementation: header, search bar, list, divider, preview,
  status. Later sub-phases add markdown rendering, link nav
  footer, command palette overlay, etc.
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
    label = "egghead — #{length(model.all)} records (#{length(model.filtered)} shown)"

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
    # The list flexes to fill the upper region. Inside, each row
    # is its own single-row text leaf in a vbox so the renderer
    # paints them at distinct y coordinates.
    rows =
      model.filtered
      |> Enum.with_index()
      |> Enum.map(fn {record, idx} ->
        list_row(record, idx, model.selection, width)
      end)

    # Wrap rows in a vbox; the vbox itself is flex 1 so it
    # takes the remaining space after the fixed header/search/
    # divider/status panes.
    vbox([flex: 1], rows)
  end

  defp list_row(record, idx, selection, width) do
    is_selected = idx == selection
    label = record.id || ""
    time_str = format_time(record.updated)

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
        header_line = preview_header(id, width)

        body_rows =
          (model.selected_body || "")
          |> String.split("\n")
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

  defp preview_header(id, width) do
    base = "── #{id} "
    pad = max(width - String.length(base), 0)

    text(truncate(base <> String.duplicate("─", pad), width),
      height: 1,
      fg: Colors.dim(),
      bg: Colors.bg()
    )
  end

  defp status_bar(width) do
    label = " ↑↓ select  ·  type to filter  ·  esc / ctrl-c quit"

    text(truncate(label, width),
      height: 1,
      fg: Colors.white(),
      bg: Colors.dim()
    )
  end

  # ---- helpers ------------------------------------------------------------

  defp format_time(nil), do: "         "

  defp format_time(s) when is_binary(s) do
    case String.split(s, "T", parts: 2) do
      [date | _] -> date
      _ -> s
    end
  end

  defp truncate(str, max) when is_binary(str) and is_integer(max) and max > 0 do
    if String.length(str) <= max, do: str, else: String.slice(str, 0, max)
  end

  defp truncate(_str, _max), do: ""
end
