defmodule Egghead.TUI.TestHelpers do
  @moduledoc """
  Helpers for inspecting TermUI buffer contents in tests and debugging.

  The buffer is the structured IR — the source of truth for what's
  rendered on screen. These helpers let tests and the /debug command
  read it as text and style data.
  """

  alias TermUI.Renderer.{Buffer, BufferManager}
  alias TermUI.Runtime.NodeRenderer

  @doc """
  Renders a view tree into a fresh buffer and returns it.
  """
  def render_to_test_buffer(tree, rows, cols, name \\ :test_render) do
    # Stop any existing buffer with this name
    try do
      GenServer.stop(name)
    catch
      :exit, _ -> :ok
    end

    {:ok, _} = BufferManager.start_link(rows: rows, cols: cols, name: name)
    BufferManager.clear_current(name)
    NodeRenderer.render_to_buffer(tree, name)
    BufferManager.get_current_buffer(name)
  end

  @doc """
  Returns the text content of a buffer row as a trimmed string.
  """
  def row_text(buffer, row) do
    buffer
    |> Buffer.get_row(row)
    |> Enum.map(& &1.char)
    |> Enum.join()
    |> String.trim_trailing()
  end

  @doc """
  Returns the fg color of a cell.
  """
  def cell_fg(buffer, row, col) do
    Buffer.get_cell(buffer, row, col).fg
  end

  @doc """
  Returns the bg color of a cell.
  """
  def cell_bg(buffer, row, col) do
    Buffer.get_cell(buffer, row, col).bg
  end

  @doc """
  Dumps the entire buffer as a readable text representation.
  Returns a string with line numbers and content.
  """
  def dump_text(buffer) do
    {rows, _cols} = Buffer.dimensions(buffer)

    1..rows
    |> Enum.map(fn row ->
      text = row_text(buffer, row)
      "[#{String.pad_leading("#{row}", 3, "0")}] #{text}"
    end)
    |> Enum.join("\n")
  end

  @doc """
  Dumps buffer with style info for debugging.
  Returns a string with line numbers, fg/bg per first cell.
  """
  def dump_styles(buffer) do
    {rows, cols} = Buffer.dimensions(buffer)

    1..rows
    |> Enum.map(fn row ->
      first = Buffer.get_cell(buffer, row, 1)
      last = Buffer.get_cell(buffer, row, cols)
      text = row_text(buffer, row) |> String.slice(0, 40)

      last_info =
        if last.char != " ", do: " | last=#{inspect(last.char)} fg=#{inspect(last.fg)}", else: ""

      "[#{String.pad_leading("#{row}", 3, "0")}] fg=#{inspect(first.fg)} bg=#{inspect(first.bg)} #{text}#{last_info}"
    end)
    |> Enum.join("\n")
  end

  @doc """
  Dumps the current live buffer (from the running TUI) to a file.
  Uses the default BufferManager which is stored in :persistent_term.
  """
  def dump_live_buffer(path \\ "/tmp/egghead_render.txt") do
    buffer = BufferManager.get_current_buffer()
    text_dump = dump_text(buffer)
    style_dump = dump_styles(buffer)

    content = """
    === EGGHEAD TUI RENDER DUMP ===
    #{DateTime.utc_now()}

    === TEXT ===
    #{text_dump}

    === STYLES ===
    #{style_dump}
    """

    File.write!(path, content)
    {:ok, path}
  rescue
    e -> {:error, Exception.message(e)}
  end
end
