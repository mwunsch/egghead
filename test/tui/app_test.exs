defmodule Egghead.TUI.AppTest do
  # async: false to avoid conflicts with other tests that manage PubSub
  use ExUnit.Case, async: false

  alias TermUI.Runtime
  alias TermUI.Event

  # Start the Runtime headless (skip_terminal: true) so no actual terminal is needed.
  # This lets us send events, sync, and inspect state programmatically.
  # The Egghead application must be running (RecordStore, Index, etc.)

  # TUI integration tests need the full RecordStore running.
  # Test config disables it, so we start it manually here.
  setup_all do
    records_dir = Path.join(File.cwd!(), "records")
    db_path = Path.join(records_dir, ".egghead/index.db")

    # Start PubSub if not running
    unless GenServer.whereis(Egghead.PubSub) do
      Phoenix.PubSub.Supervisor.start_link(name: Egghead.PubSub)
    end

    # Start RecordSupervisor (Index + RecordStore) if not running
    unless GenServer.whereis(Egghead.Index) do
      Egghead.RecordSupervisor.start_link(records_dir: records_dir, db_path: db_path)
    end

    # Wait for file watcher to index
    Process.sleep(500)
    :ok
  end

  defp start_headless do
    {:ok, runtime} = Runtime.start_link(root: Egghead.TUI.App, skip_terminal: true)
    Runtime.sync(runtime)
    runtime
  end

  defp get_app_state(runtime) do
    state = Runtime.get_state(runtime)
    state.root_state
  end

  defp send_key(runtime, key, opts \\ []) do
    event = Event.Key.new(key, opts)
    Runtime.send_event(runtime, event)
    Runtime.sync(runtime)
  end

  defp send_char(runtime, char) do
    send_key(runtime, char, char: char)
  end

  describe "init" do
    test "loads records and sets initial state" do
      runtime = start_headless()
      state = get_app_state(runtime)

      assert state.mode == :records
      assert is_list(state.results)
      assert length(state.results) > 0
      assert state.selected == 0
      assert state.query == ""
      assert state.preview_scroll == 0
      # Default: durable only
      assert state.show_all_classes == false

      Runtime.shutdown(runtime)
    end

    test "preview is loaded for first record" do
      runtime = start_headless()
      state = get_app_state(runtime)

      assert state.preview != nil
      assert state.preview.body != nil

      Runtime.shutdown(runtime)
    end
  end

  describe "search" do
    test "typing filters results" do
      runtime = start_headless()

      # Type "coord" — should filter to coordinator-related records
      for char <- String.graphemes("coord") do
        send_char(runtime, char)
      end

      state = get_app_state(runtime)
      assert state.query == "coord"
      assert length(state.results) > 0

      # All results should contain "coord" in id, title, or tags
      for record <- state.results do
        match =
          String.contains?(String.downcase(record.id), "coord") or
            (record.title && String.contains?(String.downcase(record.title), "coord")) or
            Enum.any?(record.tags || [], &String.contains?(String.downcase(&1), "coord"))

        assert match, "Record #{record.id} should match 'coord'"
      end

      Runtime.shutdown(runtime)
    end

    test "backspace removes characters from query" do
      runtime = start_headless()

      send_char(runtime, "a")
      send_char(runtime, "b")
      send_char(runtime, "c")

      state = get_app_state(runtime)
      assert state.query == "abc"

      send_key(runtime, :backspace)
      state = get_app_state(runtime)
      assert state.query == "ab"

      Runtime.shutdown(runtime)
    end

    test "all printable characters work in search including q" do
      runtime = start_headless()

      send_char(runtime, "q")
      state = get_app_state(runtime)
      assert state.query == "q"
      # Should NOT quit — q is just a search character
      assert Process.alive?(runtime)

      Runtime.shutdown(runtime)
    end
  end

  describe "navigation" do
    test "arrow down increments selected" do
      runtime = start_headless()

      send_key(runtime, :down)
      state = get_app_state(runtime)
      assert state.selected == 1

      send_key(runtime, :down)
      state = get_app_state(runtime)
      assert state.selected == 2

      Runtime.shutdown(runtime)
    end

    test "arrow up decrements selected" do
      runtime = start_headless()

      send_key(runtime, :down)
      send_key(runtime, :down)
      send_key(runtime, :up)

      state = get_app_state(runtime)
      assert state.selected == 1

      Runtime.shutdown(runtime)
    end

    test "arrow up at top stays at 0" do
      runtime = start_headless()

      send_key(runtime, :up)
      state = get_app_state(runtime)
      assert state.selected == 0

      Runtime.shutdown(runtime)
    end

    test "navigation resets preview scroll" do
      runtime = start_headless()

      # Scroll preview down
      send_key(runtime, "j", modifiers: [:ctrl])
      state = get_app_state(runtime)
      assert state.preview_scroll == 5

      # Navigate — should reset preview scroll
      send_key(runtime, :down)
      state = get_app_state(runtime)
      assert state.preview_scroll == 0

      Runtime.shutdown(runtime)
    end
  end

  describe "preview scroll" do
    test "Ctrl+J scrolls preview down" do
      runtime = start_headless()

      send_key(runtime, "j", modifiers: [:ctrl])
      state = get_app_state(runtime)
      assert state.preview_scroll == 5

      send_key(runtime, "j", modifiers: [:ctrl])
      state = get_app_state(runtime)
      assert state.preview_scroll == 10

      Runtime.shutdown(runtime)
    end

    test "Ctrl+K scrolls preview up" do
      runtime = start_headless()

      # Scroll down first
      send_key(runtime, "j", modifiers: [:ctrl])
      send_key(runtime, "j", modifiers: [:ctrl])

      state = get_app_state(runtime)
      assert state.preview_scroll == 10

      send_key(runtime, "k", modifiers: [:ctrl])
      state = get_app_state(runtime)
      assert state.preview_scroll == 5

      Runtime.shutdown(runtime)
    end

    test "Ctrl+K doesn't go below 0" do
      runtime = start_headless()

      send_key(runtime, "k", modifiers: [:ctrl])
      state = get_app_state(runtime)
      assert state.preview_scroll == 0

      Runtime.shutdown(runtime)
    end
  end

  describe "filter toggle" do
    test "tab toggles between durable-only and all" do
      runtime = start_headless()

      state = get_app_state(runtime)
      assert state.show_all_classes == false
      durable_count = length(state.results)

      send_key(runtime, :tab)
      state = get_app_state(runtime)
      assert state.show_all_classes == true
      all_count = length(state.results)
      assert all_count >= durable_count

      send_key(runtime, :tab)
      state = get_app_state(runtime)
      assert state.show_all_classes == false

      Runtime.shutdown(runtime)
    end
  end

  describe "quit" do
    test "Ctrl+Q sends quit" do
      runtime = start_headless()
      ref = Process.monitor(runtime)

      send_key(runtime, "q", modifiers: [:ctrl])

      assert_receive {:DOWN, ^ref, :process, ^runtime, _}, 2000
    end
  end

  describe "command mode" do
    test "/ enters command mode" do
      runtime = start_headless()

      send_char(runtime, "/")
      state = get_app_state(runtime)
      assert state.command_mode == true
      assert state.command_input == ""

      Runtime.shutdown(runtime)
    end

    test "escape exits command mode" do
      runtime = start_headless()

      send_char(runtime, "/")
      send_key(runtime, :escape)
      state = get_app_state(runtime)
      assert state.command_mode == false

      Runtime.shutdown(runtime)
    end
  end
end
