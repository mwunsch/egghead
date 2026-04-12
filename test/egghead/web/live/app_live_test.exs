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
    test "mounts with three-pane layout", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      assert html =~ "egghead"
      assert has_element?(view, ".nav-sidebar")
      assert has_element?(view, ".record-pane")
      assert has_element?(view, ".chat-sidebar")
    end

    test "toggle nav sidebar", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Nav should be open by default
      assert has_element?(view, ".nav-sidebar:not(.collapsed)")

      # Toggle it closed
      view |> element(".header-left .header-btn") |> render_click()
      assert has_element?(view, ".nav-sidebar.collapsed")

      # Toggle it back open
      view |> element(".header-left .header-btn") |> render_click()
      assert has_element?(view, ".nav-sidebar:not(.collapsed)")
    end

    test "toggle chat sidebar", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".chat-sidebar:not(.collapsed)")

      view |> element(".header-right .header-btn") |> render_click()
      assert has_element?(view, ".chat-sidebar.collapsed")
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
      refute html =~ "Design Document"
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
      {:ok, _view, html} = live(conn, "/?id=hello-world")

      assert html =~ "Hello World"
      assert html =~ "test record"
    end

    test "properties block shows tags", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/?id=hello-world")

      assert html =~ "greeting"
      assert html =~ "tag-pill"
    end

    test "wikilinks render with brackets", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/?id=hello-world")

      assert html =~ "data-wikilink=\"link-target\""
      assert html =~ "wikilink"
    end

    test "wikilink click navigates via patch", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/?id=hello-world")

      view |> element("a[data-wikilink=\"link-target\"]") |> render_click()

      html = render(view)
      assert html =~ "Link Target"
      assert html =~ "linked from"
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

      send(view.pid, {:agent_streaming, room_id, "agents/scout", "Hello world\n"})
      Process.sleep(50)

      html = render(view)
      assert html =~ "Hello world"
    end

    test "budget exhausted shows status", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, :budget_exhausted)
      Process.sleep(50)

      assert render(view) =~ "Budget exhausted"
    end
  end
end
