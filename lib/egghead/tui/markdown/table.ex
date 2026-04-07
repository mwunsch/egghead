defmodule Egghead.TUI.Markdown.Table do
  @moduledoc """
  Renders Earmark GFM table AST nodes to styled terminal lines.

  The Earmark AST shape for a table:

      {"table", [], [
        {"thead", [], [{"tr", [], [{"th", [{"style", "text-align: left;"}], ["Header"], %{}}, ...], %{}}], %{}},
        {"tbody", [], [{"tr", [], [{"td", [{"style", "..."}], ["Cell"], %{}}, ...], %{}}, ...], %{}}
      ], %{}}

  We extract a list of rows + an alignment list, compute column widths,
  and render with Unicode box-drawing characters.
  """

  alias Egghead.TUI.Theme

  @doc """
  Render a table AST node to a list of {string, style} tuples.

  Returns lines bounded to `width` characters total, including borders.
  Header row uses bold, body rows use the default text style.
  """
  @spec render(list(), pos_integer()) :: [{String.t(), TermUI.Renderer.Style.t()}]
  def render(table_children, width) do
    {header_row, body_rows, aligns} = collect_rows(table_children)

    case header_row do
      nil ->
        # Malformed table — fall back to text extraction
        []

      _ ->
        all_rows = [header_row | body_rows]
        col_count = max(length(header_row), max_row_length(body_rows))
        widths = compute_col_widths(all_rows, col_count, width)
        aligns = pad_aligns(aligns, col_count)

        top = border_line(:top, widths)
        sep = border_line(:mid, widths)
        bot = border_line(:bot, widths)

        header_line = render_row(header_row, widths, aligns, true)
        body_lines = Enum.map(body_rows, &render_row(&1, widths, aligns, false))

        sep_style = Theme.separator()
        head_style = Theme.md_h3()
        body_style = Theme.normal()

        [
          {top, sep_style},
          {header_line, head_style},
          {sep, sep_style}
        ] ++
          Enum.map(body_lines, fn line -> {line, body_style} end) ++
          [{bot, sep_style}, {"", nil}]
    end
  end

  # --- AST extraction ---

  defp collect_rows(table_children) do
    Enum.reduce(table_children, {nil, [], []}, fn
      {"thead", _, [tr | _], _}, {_, body, _} ->
        {row, aligns} = extract_tr(tr)
        {row, body, aligns}

      {"tbody", _, trs, _}, {head, _body, aligns} ->
        rows = Enum.map(trs, fn tr -> elem(extract_tr(tr), 0) end)
        {head, rows, aligns}

      _, acc ->
        acc
    end)
  end

  defp extract_tr({"tr", _, cells, _}) do
    {texts, aligns} =
      cells
      |> Enum.map(fn
        {tag, attrs, children, _} when tag in ["th", "td"] ->
          text = text_content(children)
          align = parse_align(attrs)
          {text, align}

        _ ->
          {"", :left}
      end)
      |> Enum.unzip()

    {texts, aligns}
  end

  defp extract_tr(_), do: {[], []}

  defp text_content(children) when is_list(children) do
    Enum.map_join(children, "", fn
      text when is_binary(text) -> text
      {_tag, _attrs, nested, _meta} -> text_content(nested)
    end)
  end

  defp text_content(_), do: ""

  defp parse_align(attrs) do
    case List.keyfind(attrs, "style", 0) do
      {"style", style} ->
        cond do
          String.contains?(style, "center") -> :center
          String.contains?(style, "right") -> :right
          true -> :left
        end

      _ ->
        :left
    end
  end

  defp pad_aligns(aligns, col_count) do
    aligns ++ List.duplicate(:left, max(0, col_count - length(aligns)))
  end

  defp max_row_length([]), do: 0
  defp max_row_length(rows), do: rows |> Enum.map(&length/1) |> Enum.max()

  # --- Column widths ---

  # Each column gets max(content_width) capped to fit overall width.
  # Borders take 1 char each: "│ col1 │ col2 │" = (cols * 3 + 1) extra chars.
  defp compute_col_widths(all_rows, col_count, max_width) do
    natural =
      Enum.map(0..(col_count - 1), fn col ->
        all_rows
        |> Enum.map(fn row ->
          case Enum.at(row, col) do
            nil -> 0
            text -> String.length(text)
          end
        end)
        |> Enum.max(fn -> 1 end)
        |> max(1)
      end)

    # Total width if we used natural widths: sum + borders
    overhead = col_count * 3 + 1
    available = max(col_count, max_width - overhead)
    natural_total = Enum.sum(natural)

    if natural_total <= available do
      natural
    else
      # Scale down proportionally
      Enum.map(natural, fn w ->
        max(1, round(w / natural_total * available))
      end)
    end
  end

  # --- Row rendering ---

  defp border_line(kind, widths) do
    {left, mid, right} =
      case kind do
        :top -> {"┌", "┬", "┐"}
        :mid -> {"├", "┼", "┤"}
        :bot -> {"└", "┴", "┘"}
      end

    parts = Enum.map(widths, fn w -> String.duplicate("─", w + 2) end)
    left <> Enum.join(parts, mid) <> right
  end

  defp render_row(cells, widths, aligns, _header?) do
    rendered_cells =
      widths
      |> Enum.with_index()
      |> Enum.map(fn {w, i} ->
        text = Enum.at(cells, i, "")
        align = Enum.at(aligns, i, :left)
        " " <> pad_cell(text, w, align) <> " "
      end)

    "│" <> Enum.join(rendered_cells, "│") <> "│"
  end

  defp pad_cell(text, width, align) do
    truncated = String.slice(text, 0, width)
    len = String.length(truncated)
    pad_total = max(0, width - len)

    case align do
      :left ->
        truncated <> String.duplicate(" ", pad_total)

      :right ->
        String.duplicate(" ", pad_total) <> truncated

      :center ->
        left = div(pad_total, 2)
        right = pad_total - left
        String.duplicate(" ", left) <> truncated <> String.duplicate(" ", right)
    end
  end
end
