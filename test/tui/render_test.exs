defmodule Egghead.TUI.RenderTest do
  use ExUnit.Case, async: false

  alias TermUI.Renderer.Buffer
  alias Egghead.TUI.{App, State, TestHelpers}

  # Start RecordStore for real data
  setup_all do
    records_dir = Path.join(File.cwd!(), "records")
    db_path = Path.join(records_dir, ".egghead/index.db")

    unless GenServer.whereis(Egghead.PubSub) do
      Phoenix.PubSub.Supervisor.start_link(name: Egghead.PubSub)
    end

    unless GenServer.whereis(Egghead.Index) do
      Egghead.RecordSupervisor.start_link(records_dir: records_dir, db_path: db_path)
    end

    Process.sleep(500)
    :ok
  end

  defp render_view(width \\ 80, height \\ 24) do
    # Build state manually (skip Terminal calls that fail in test)
    all_records = Egghead.list_records()

    durable =
      Enum.filter(all_records, &(&1.class == :durable)) |> Enum.sort_by(& &1.updated, :desc)

    preview =
      case Enum.at(durable, 0) do
        nil ->
          nil

        r ->
          case Egghead.get_record(r.id) do
            {:ok, full} -> full
            _ -> r
          end
      end

    state = %State{
      width: width,
      height: height,
      all_records: all_records,
      results: durable,
      agents: [],
      preview: preview
    }

    tree = App.view(state)

    buf =
      TestHelpers.render_to_test_buffer(
        tree,
        height,
        width,
        :"render_test_#{:rand.uniform(999_999)}"
      )

    {buf, state}
  end

  describe "header" do
    test "renders egghead at row 1" do
      {buf, _} = render_view()
      text = TestHelpers.row_text(buf, 1)
      assert text =~ "egghead"
    end

    test "header has cyan foreground" do
      {buf, _} = render_view()
      # " egghead" — col 2 is "e"
      assert TestHelpers.cell_fg(buf, 1, 2) == :cyan
    end

    test "header has background color" do
      {buf, _} = render_view()
      assert TestHelpers.cell_bg(buf, 1, 1) == :bright_black
    end

    test "header shows record count" do
      {buf, state} = render_view()
      text = TestHelpers.row_text(buf, 1)
      assert text =~ "#{length(state.results)} records"
    end
  end

  describe "search bar" do
    test "renders prompt at row 2" do
      {buf, _} = render_view()
      text = TestHelpers.row_text(buf, 2)
      assert text =~ "❯"
    end

    test "search bar has cyan foreground" do
      {buf, _} = render_view()
      assert TestHelpers.cell_fg(buf, 2, 2) == :cyan
    end
  end

  describe "note list" do
    test "first record is highlighted" do
      {buf, _} = render_view()
      # Row 3 = separator, row 4 = first list item (selected)
      assert TestHelpers.cell_bg(buf, 4, 1) == :cyan
      assert TestHelpers.cell_fg(buf, 4, 1) == :black
    end

    test "second record has normal style" do
      {buf, _} = render_view()
      # Row 5 is second list item (not selected)
      fg = TestHelpers.cell_fg(buf, 5, 2)
      assert fg == :white
    end

    test "list items contain record titles" do
      {buf, state} = render_view()
      first_title = Enum.at(state.results, 0).title || Enum.at(state.results, 0).id
      text = TestHelpers.row_text(buf, 4)
      # Title should appear somewhere in the row
      assert text =~ String.slice(first_title, 0, 20)
    end
  end

  describe "preview" do
    test "preview label contains record id" do
      {buf, state} = render_view()
      # Preview label is after list + blank line
      # For 24 rows: body=19, list_h=6, so preview starts at row 2+6+1+1=10
      {_, label_row} = find_preview_label(buf, 24)
      text = TestHelpers.row_text(buf, label_row)
      assert text =~ "preview:"
      assert text =~ state.preview.id
    end

    test "preview has markdown content" do
      # Use a larger terminal to ensure preview has content rows
      {buf, _} = render_view(120, 40)
      {_, label_row} = find_preview_label(buf, 40)

      content =
        Enum.find_value(1..5, fn offset ->
          text = TestHelpers.row_text(buf, label_row + offset)
          if String.length(text) > 0, do: text
        end)

      assert content != nil
    end
  end

  describe "status bar" do
    test "status bar at last row" do
      {buf, _} = render_view(80, 24)
      text = TestHelpers.row_text(buf, 24)
      assert text =~ "REC"
    end

    test "status bar has background" do
      {buf, _} = render_view(80, 24)
      assert TestHelpers.cell_bg(buf, 24, 1) == :bright_black
    end
  end

  describe "different terminal sizes" do
    test "renders at 80x24 without overflow" do
      {buf, _} = render_view(80, 24)
      {rows, cols} = Buffer.dimensions(buf)
      assert rows == 24
      assert cols == 80
      # Header should exist
      assert TestHelpers.row_text(buf, 1) =~ "egghead"
    end

    test "renders at 120x40 without overflow" do
      {buf, _} = render_view(120, 40)
      assert TestHelpers.row_text(buf, 1) =~ "egghead"
      # More list items visible
      text_row10 = TestHelpers.row_text(buf, 10)
      assert String.length(text_row10) > 0
    end

    test "renders at 200x50 without overflow" do
      {buf, _} = render_view(200, 50)
      assert TestHelpers.row_text(buf, 1) =~ "egghead"
    end
  end

  describe "command mode rendering" do
    test "search bar shows /command_input when in command mode" do
      state = cmd_state("deb")

      tree = App.view(state)
      buf = TestHelpers.render_to_test_buffer(tree, 24, 80, :"cmd_test_#{:rand.uniform(999_999)}")
      text = TestHelpers.row_text(buf, 2)
      assert text =~ "/deb"
    end

    test "autocomplete dropdown shows filtered commands" do
      state = cmd_state("h")

      tree = App.view(state)
      buf = TestHelpers.render_to_test_buffer(tree, 24, 80, :"cmd_dd_#{:rand.uniform(999_999)}")
      # Row 3 = separator, row 4 = first dropdown item
      text = TestHelpers.row_text(buf, 4)
      assert text =~ "/help"
    end

    test "selected command in dropdown is highlighted" do
      state = cmd_state("", 1)

      tree = App.view(state)
      buf = TestHelpers.render_to_test_buffer(tree, 24, 80, :"cmd_sel_#{:rand.uniform(999_999)}")

      # Row 4 = first command (not selected, default bg), Row 5 = second command (selected, cyan bg)
      assert TestHelpers.cell_bg(buf, 4, 1) == :default
      assert TestHelpers.cell_bg(buf, 5, 1) == :cyan
    end

    test "status bar shows CMD mode hint in command mode" do
      state = cmd_state("")

      tree = App.view(state)
      buf = TestHelpers.render_to_test_buffer(tree, 24, 80, :"cmd_st_#{:rand.uniform(999_999)}")
      # Status bar is always the last rendered row
      # Find it by scanning for CMD
      found =
        Enum.any?(1..24, fn row ->
          TestHelpers.row_text(buf, row) =~ "CMD"
        end)

      assert found
    end
  end

  defp cmd_state(input, selected \\ 0) do
    all_records = Egghead.list_records()

    durable =
      Enum.filter(all_records, &(&1.class == :durable)) |> Enum.sort_by(& &1.updated, :desc)

    %State{
      width: 80,
      height: 24,
      all_records: all_records,
      results: durable,
      agents: [],
      preview: nil,
      command_mode: true,
      command_input: input,
      command_selected: selected
    }
  end

  # Helper to find the preview label row by scanning for "preview:"
  defp find_preview_label(buf, height) do
    Enum.find_value(1..height, fn row ->
      text = TestHelpers.row_text(buf, row)
      if text =~ "preview:", do: {:found, row}
    end) || {:not_found, 0}
  end
end
