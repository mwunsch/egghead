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
    test "Ctrl+F toggles between durable-only and all" do
      runtime = start_headless()

      state = get_app_state(runtime)
      assert state.show_all_classes == false
      durable_count = length(state.results)

      send_key(runtime, "f", modifiers: [:ctrl])
      state = get_app_state(runtime)
      assert state.show_all_classes == true
      all_count = length(state.results)
      assert all_count >= durable_count

      send_key(runtime, "f", modifiers: [:ctrl])
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

    test "typing in command mode appends to command_input" do
      runtime = start_headless()

      send_char(runtime, "/")
      send_char(runtime, "d")
      send_char(runtime, "e")
      send_char(runtime, "b")

      state = get_app_state(runtime)
      assert state.command_mode == true
      assert state.command_input == "deb"

      Runtime.shutdown(runtime)
    end

    test "enter executes command and exits command mode" do
      runtime = start_headless()

      send_char(runtime, "/")
      send_char(runtime, "d")
      send_char(runtime, "e")
      send_char(runtime, "b")
      send_key(runtime, :enter)

      state = get_app_state(runtime)
      assert state.command_mode == false
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

    test "arrow up/down navigates command list" do
      runtime = start_headless()

      send_char(runtime, "/")
      state = get_app_state(runtime)
      assert state.command_selected == 0

      send_key(runtime, :down)
      state = get_app_state(runtime)
      assert state.command_selected == 1

      send_key(runtime, :down)
      state = get_app_state(runtime)
      assert state.command_selected == 2

      send_key(runtime, :up)
      state = get_app_state(runtime)
      assert state.command_selected == 1

      Runtime.shutdown(runtime)
    end

    test "typing resets command selection to 0" do
      runtime = start_headless()

      send_char(runtime, "/")
      send_key(runtime, :down)
      send_key(runtime, :down)
      state = get_app_state(runtime)
      assert state.command_selected == 2

      send_char(runtime, "h")
      state = get_app_state(runtime)
      assert state.command_selected == 0
      assert state.command_input == "h"

      Runtime.shutdown(runtime)
    end

    test "/help sets preview to help content" do
      runtime = start_headless()

      send_char(runtime, "/")
      send_char(runtime, "h")
      send_char(runtime, "e")
      send_key(runtime, :enter)

      state = get_app_state(runtime)
      assert state.command_mode == false
      assert state.preview != nil
      assert state.preview.id == "help"
      assert state.preview.body =~ "Keybindings"

      Runtime.shutdown(runtime)
    end
  end

  describe "link navigation" do
    test "tab cycles link_index through preview_links" do
      runtime = start_headless()

      state = get_app_state(runtime)
      assert state.link_index == nil

      # Only test if the first record has links
      if state.preview_links != [] do
        send_key(runtime, :tab)
        state = get_app_state(runtime)
        assert state.link_index == 0

        send_key(runtime, :tab)
        state = get_app_state(runtime)
        assert state.link_index == 1 or length(state.preview_links) == 1
      end

      Runtime.shutdown(runtime)
    end

    test "escape deselects link" do
      runtime = start_headless()

      state = get_app_state(runtime)

      if state.preview_links != [] do
        send_key(runtime, :tab)
        state = get_app_state(runtime)
        assert state.link_index == 0

        send_key(runtime, :escape)
        state = get_app_state(runtime)
        assert state.link_index == nil
      end

      Runtime.shutdown(runtime)
    end

    test "follow_link navigates to linked record and pushes history" do
      runtime = start_headless()

      state = get_app_state(runtime)

      if state.preview_links != [] do
        original_id = state.preview.id

        send_key(runtime, :tab)
        send_key(runtime, :enter)

        state = get_app_state(runtime)
        # Should have navigated — preview changed, history has original
        assert state.nav_history == [original_id]
        assert state.link_index == nil
      end

      Runtime.shutdown(runtime)
    end

    test "nav_back returns to previous preview" do
      runtime = start_headless()

      state = get_app_state(runtime)

      if state.preview_links != [] do
        original_id = state.preview.id

        # Navigate forward
        send_key(runtime, :tab)
        send_key(runtime, :enter)

        # Navigate back
        send_key(runtime, :backspace)

        state = get_app_state(runtime)
        assert state.preview.id == original_id
        assert state.nav_history == []
      end

      Runtime.shutdown(runtime)
    end
  end

  describe "search-as-create (phantom row)" do
    test "no phantom for empty query" do
      runtime = start_headless()
      state = get_app_state(runtime)
      assert state.query == ""

      # Selection should not be at phantom (no phantom present)
      total = length(state.results)
      assert state.selected < total or total == 0

      Runtime.shutdown(runtime)
    end

    test "phantom appears when query has no exact match and is valid" do
      runtime = start_headless()

      # Type a unique id that won't match anything
      for char <- String.graphemes("nonexistent-test-record") do
        send_char(runtime, char)
      end

      state = get_app_state(runtime)
      assert state.query == "nonexistent-test-record"

      # Phantom row sits at index length(results)
      phantom_idx = length(state.results)

      # Move down to reach the phantom
      Enum.each(0..phantom_idx, fn _ -> send_key(runtime, :down) end)

      state = get_app_state(runtime)
      assert state.selected == phantom_idx

      # Preview should be the phantom hint, not a real record
      assert state.preview != nil
      assert state.preview.id == "nonexistent-test-record"
      assert state.preview.title == "nonexistent-test-record"
      assert state.preview.body =~ "Create new record"

      Runtime.shutdown(runtime)
    end

    test "no phantom when query is empty after typing then backspacing" do
      runtime = start_headless()

      send_char(runtime, "x")
      send_key(runtime, :backspace)

      state = get_app_state(runtime)
      assert state.query == ""

      # Phantom should not exist; preview should be a real record
      assert state.preview.id != ""
      assert state.preview.title != "New Record"

      Runtime.shutdown(runtime)
    end

    test "title with spaces is slugified for the id" do
      runtime = start_headless()

      for char <- String.graphemes("Notational Velocity") do
        send_char(runtime, char)
      end

      state = get_app_state(runtime)
      assert state.query == "Notational Velocity"

      # Phantom should be reachable; preview shows slug
      phantom_idx = length(state.results)
      Enum.each(0..phantom_idx, fn _ -> send_key(runtime, :down) end)

      state = get_app_state(runtime)
      assert state.selected == phantom_idx
      assert state.preview != nil
      assert state.preview.id == "notational-velocity"
      assert state.preview.title == "Notational Velocity"

      Runtime.shutdown(runtime)
    end

    test "garbage query (only special chars) shows no phantom" do
      runtime = start_headless()

      for char <- String.graphemes("!@#$") do
        send_char(runtime, char)
      end

      state = get_app_state(runtime)
      assert state.query == "!@#$"

      # Slugifies to empty → no phantom
      total_before = length(state.results)
      Enum.each(0..(total_before + 5), fn _ -> send_key(runtime, :down) end)

      state = get_app_state(runtime)
      max_valid = max(0, length(state.results) - 1)
      assert state.selected == max_valid

      Runtime.shutdown(runtime)
    end
  end

  describe "chat mode" do
    # Helper: synthesize a Room.Message struct for ingestion tests
    defp user_msg(content, name \\ "tester") do
      %{
        id: "msg-#{:erlang.unique_integer([:positive])}",
        room_id: "test-room",
        sender: %{type: :user, id: name, name: name},
        content: content,
        timestamp: DateTime.utc_now(),
        mentions: [],
        usage: nil
      }
    end

    defp agent_msg(content, agent_id, opts \\ []) do
      %{
        id: "msg-#{:erlang.unique_integer([:positive])}",
        room_id: "test-room",
        sender: %{type: :agent, id: agent_id, name: agent_id},
        content: content,
        timestamp: DateTime.utc_now(),
        mentions: [],
        usage: opts[:usage]
      }
    end

    # Drive the runtime directly with a message (bypassing PubSub)
    defp send_room_event(runtime, event) do
      pid = runtime
      send(pid, event)
      Runtime.sync(runtime)
    end

    defp enter_chat_via_command(runtime) do
      # Open command palette via "/", then "chat", then enter
      send_char(runtime, "/")
      Runtime.sync(runtime)
      for c <- String.graphemes("chat"), do: send_char(runtime, c)
      send_key(runtime, :enter)
      Runtime.sync(runtime)
    end

    test "/chat enters chat mode" do
      runtime = start_headless()
      enter_chat_via_command(runtime)

      state = get_app_state(runtime)
      assert state.mode == :chat
      assert is_binary(state.chat_room_id)

      Runtime.shutdown(runtime)
    end

    test "esc leaves chat mode" do
      runtime = start_headless()
      enter_chat_via_command(runtime)

      send_key(runtime, :escape)
      state = get_app_state(runtime)
      assert state.mode == :records
      assert state.chat_room_id == nil

      Runtime.shutdown(runtime)
    end

    test "typing in chat appends to chat_input" do
      runtime = start_headless()
      enter_chat_via_command(runtime)

      for c <- String.graphemes("hello"), do: send_char(runtime, c)
      state = get_app_state(runtime)
      assert state.chat_input == "hello"

      Runtime.shutdown(runtime)
    end

    test "Ctrl+J pushes current input to extras and starts new line" do
      runtime = start_headless()
      enter_chat_via_command(runtime)

      for c <- String.graphemes("first"), do: send_char(runtime, c)
      send_key(runtime, "j", modifiers: [:ctrl])
      for c <- String.graphemes("second"), do: send_char(runtime, c)

      state = get_app_state(runtime)
      assert state.chat_input_extra_lines == ["first"]
      assert state.chat_input == "second"

      Runtime.shutdown(runtime)
    end

    test "user_message room event appends to transcript" do
      runtime = start_headless()
      enter_chat_via_command(runtime)

      send_room_event(runtime, {:user_message, user_msg("hi all")})

      state = get_app_state(runtime)
      assert length(state.chat_messages) == 1

      [{:message, m}] = state.chat_messages
      assert m.body == "hi all"
      assert m.color == :user

      Runtime.shutdown(runtime)
    end

    test "agent_message with double-newline splits into multiple entries" do
      runtime = start_headless()
      enter_chat_via_command(runtime)

      send_room_event(
        runtime,
        {:agent_message, agent_msg("Para one.\n\nPara two.\n\nPara three.", "agents/scout")}
      )

      state = get_app_state(runtime)
      messages = Enum.filter(state.chat_messages, &match?({:message, _}, &1))
      assert length(messages) == 3
      bodies = Enum.map(messages, fn {:message, m} -> m.body end)
      assert bodies == ["Para one.", "Para two.", "Para three."]

      Runtime.shutdown(runtime)
    end

    test "agent_streaming buffers raw deltas in chat_streams" do
      runtime = start_headless()
      enter_chat_via_command(runtime)

      # Single paragraph (no \n\n) — buffered, not committed
      send_room_event(runtime, {:agent_streaming, "test-room", "agents/scout", "hello "})
      send_room_event(runtime, {:agent_streaming, "test-room", "agents/scout", "world"})

      state = get_app_state(runtime)

      assert %{"agents/scout" => %{committed: "", buffer: "hello world"}} =
               state.chat_streams

      # Crossing a paragraph boundary commits everything before \n\n
      send_room_event(runtime, {:agent_streaming, "test-room", "agents/scout", "\n\nmore"})

      state = get_app_state(runtime)

      assert %{"agents/scout" => %{committed: "hello world\n\n", buffer: "more"}} =
               state.chat_streams

      Runtime.shutdown(runtime)
    end

    test "agent_message clears chat_streams for that agent" do
      runtime = start_headless()
      enter_chat_via_command(runtime)

      send_room_event(runtime, {:agent_streaming, "test-room", "agents/scout", "draft"})
      send_room_event(runtime, {:agent_message, agent_msg("final", "agents/scout")})

      state = get_app_state(runtime)
      assert state.chat_streams == %{}
      assert Enum.any?(state.chat_messages, &match?({:message, %{body: "final"}}, &1))

      Runtime.shutdown(runtime)
    end

    test "agent_tool_call appends an action entry" do
      runtime = start_headless()
      enter_chat_via_command(runtime)

      send_room_event(
        runtime,
        {:agent_tool_call, "test-room", "agents/scout", "search_records",
         %{"query" => "encryption"}}
      )

      state = get_app_state(runtime)
      assert Enum.any?(state.chat_messages, &match?({:action, _}, &1))

      Runtime.shutdown(runtime)
    end

    test "budget_exhausted appends a system warning" do
      runtime = start_headless()
      enter_chat_via_command(runtime)

      send_room_event(runtime, :budget_exhausted)

      state = get_app_state(runtime)
      assert Enum.any?(state.chat_messages, fn
               {:system, %{kind: :warning}} -> true
               _ -> false
             end)

      Runtime.shutdown(runtime)
    end

    test "extract_mention_prefix returns prefix after @" do
      assert Egghead.TUI.App.extract_mention_prefix("hi @sc") == "sc"
      assert Egghead.TUI.App.extract_mention_prefix("hi @scout") == "scout"
      assert Egghead.TUI.App.extract_mention_prefix("hi @") == ""
      assert Egghead.TUI.App.extract_mention_prefix("plain text") == nil
      assert Egghead.TUI.App.extract_mention_prefix("@agents/sc") == "agents/sc"
      # Whitespace after @ token resets — only the last token
      assert Egghead.TUI.App.extract_mention_prefix("@scout said hi") == nil
    end

    test "find_mention_completion returns suffix to complete the match" do
      agents = [
        %{id: "agents/scout", name: "scout"},
        %{id: "agents/archivist", name: "archivist"}
      ]

      # "sc" → "out" to complete to "scout"
      assert Egghead.TUI.App.find_mention_completion(agents, "sc") == "out"
      # "arch" → "ivist"
      assert Egghead.TUI.App.find_mention_completion(agents, "arch") == "ivist"
      # No match
      assert Egghead.TUI.App.find_mention_completion(agents, "xyz") == nil
      # Exact match yields nil (no ghost when fully typed)
      assert Egghead.TUI.App.find_mention_completion(agents, "scout") == nil
    end

    test "Ctrl+G clears the input and ghost" do
      runtime = start_headless()
      enter_chat_via_command(runtime)

      for c <- String.graphemes("hello"), do: send_char(runtime, c)
      send_key(runtime, "g", modifiers: [:ctrl])

      state = get_app_state(runtime)
      assert state.chat_input == ""
      assert state.chat_ghost == nil

      Runtime.shutdown(runtime)
    end
  end
end
