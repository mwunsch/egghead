defmodule Egghead.Web.AppLiveTest do
  use Egghead.Web.ConnCase, async: false

  @moduletag :records

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "hello-world.md"), """
    ---
    title: Hello World
    tags: [greeting, test]
    ---

    This is a **test record** with a [[link-target]].
    """)

    File.write!(Path.join(tmp_dir, "link-target.md"), """
    ---
    title: Link Target
    tags: [test]
    ---

    This record is linked from [[hello-world]].
    """)

    File.write!(Path.join(tmp_dir, "design-doc.md"), """
    ---
    title: Design Document
    tags: [design]
    class: durable
    ---

    Architecture notes.
    """)

    start_record_store(tmp_dir)

    :ok
  end

  describe "layout shell" do
    test "mounts the desktop with search, record, and chat windows", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      assert html =~ "egghead"
      assert has_element?(view, ".desktop")
      assert has_element?(view, ".window[data-window-id=\"search\"]")
      assert has_element?(view, ".window[data-window-id=\"record\"]")
      assert has_element?(view, ".window[data-window-id=\"chat-window\"]")
      assert has_element?(view, ".record-pane")
    end

    test "deskbar shows entries for record, search, and chat", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".deskbar-entry[data-window-entry=\"record\"]")
      assert has_element?(view, ".deskbar-entry[data-window-entry=\"search\"]")
      assert has_element?(view, ".deskbar-entry[data-window-entry=\"chat-window\"]")
    end
  end

  describe "records navigation" do
    test "lists records in sidebar", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, ".record-item")
    end

    test "search filters records", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html =
        view |> element("form[phx-change=\"search\"]") |> render_change(%{"query" => "hello"})

      assert html =~ "Hello World"
      # Scope to the record list — the deskbar/record-tab still shows the
      # currently-selected record's title (Notational Velocity behavior),
      # so a global refute would fail on a label outside the list.
      refute html =~ ~s(<span class="record-title">Design Document)
    end

    test "clicking a record shows it in center pane", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element(".record-item", "Hello World") |> render_click()

      html = render(view)
      assert html =~ "Hello World"
      assert html =~ "test record"
      assert html =~ "properties"
    end

    test "mounting with id param shows record", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/records/hello-world")

      assert html =~ "Hello World"
      assert html =~ "test record"
    end

    test "properties block shows tags", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/records/hello-world")

      assert html =~ "greeting"
      assert html =~ "tag-pill"
    end

    test "editor mount point renders for selected record", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/records/hello-world")

      assert html =~ "phx-hook=\"YjsEditor\""
      assert html =~ "data-record-id=\"hello-world\""
      assert html =~ "record-editor"
    end

    test "link in properties navigates via patch", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/records/hello-world")

      view
      |> element("li.record-item", "Link Target")
      |> render_click()

      html = render(view)
      assert html =~ "data-record-id=\"link-target\""
    end

    test "class filter dropdown opens", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Default: all classes selected, all records visible
      html = render(view)
      assert html =~ "Design Document"
      assert html =~ "Hello World"

      # Open dropdown via the BMenuField filter button
      view |> element(".class-filter-wrap .menu-field") |> render_click()
      assert has_element?(view, ".class-dropdown")
    end

    test "phantom create row appears for new titles", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("form[phx-change=\"search\"]")
      |> render_change(%{"query" => "brand new note"})

      html = render(view)
      assert html =~ "Create"
      assert html =~ "brand-new-note"
    end

    test "shows backlinks count and word count", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/records/hello-world")

      assert html =~ "words"
      assert html =~ "backlinks"
    end
  end

  describe "chat" do
    setup do
      room_id = "web-test-#{:erlang.unique_integer([:positive])}"
      start_supervised!({Egghead.Chat.Room, id: room_id})
      :persistent_term.put(:egghead_default_room, room_id)

      on_exit(fn -> :persistent_term.erase(:egghead_default_room) end)

      {:ok, room_id: room_id}
    end

    test "chat sidebar shows input", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, "#chat-textarea")
    end

    test "agent streaming appears in transcript", %{conn: conn, room_id: room_id} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_streaming, room_id, "agents/scout", "Hello world\n\n"})
      Process.sleep(50)

      html = render(view)
      assert html =~ "Hello world"
    end

    test "budget exhausted shows status", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, :budget_exhausted)
      Process.sleep(50)

      assert render(view) =~ "continue"
    end

    test "agent joined/left appear as system messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_joined, "agents/scout"})
      Process.sleep(50)
      assert render(view) =~ "Scout joined"

      send(view.pid, {:agent_left, "agents/scout"})
      Process.sleep(50)
      assert render(view) =~ "Scout left"
    end

    test "tool call appears as action line", %{conn: conn, room_id: room_id} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_tool_call, room_id, "agents/scout", "egghead_search", %{q: "test"}})
      Process.sleep(50)

      html = render(view)
      assert html =~ "egghead_search"
      assert html =~ "meta-line"
    end

    test "chat completion corpus is pushed to client", %{conn: conn} do
      # The completion popover, candidate filtering, arrow nav, Tab,
      # and Esc are owned by the ChatInput JS hook. The server's only
      # job is to push the corpus (commands, agents, broadcasts,
      # records) to the client; the rest is verified in the browser,
      # not here. Assert that the `chat_corpus` event fires with at
      # least the hardcoded slash commands so a regression on the
      # push_chat_corpus path is caught.
      {:ok, view, _html} = live(conn, "/")
      assert_push_event(view, "chat_corpus", %{commands: commands})
      assert is_list(commands)
      assert Enum.any?(commands, &(&1.name == "save"))
    end

    test "toggle agent roster", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element(".chat-header .roster-toggle") |> render_click()
      assert has_element?(view, ".chat-roster")
    end
  end
end
