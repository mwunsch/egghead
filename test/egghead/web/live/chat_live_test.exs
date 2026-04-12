defmodule Egghead.Web.ChatLiveTest do
  use Egghead.Web.ConnCase, async: false

  alias Egghead.Chat.Room

  setup do
    room_id = "web-chat-test-#{:erlang.unique_integer([:positive])}"
    start_supervised!({Room, id: room_id})
    :persistent_term.put(:egghead_default_room, room_id)

    on_exit(fn ->
      :persistent_term.erase(:egghead_default_room)
    end)

    {:ok, room_id: room_id}
  end

  test "mounts and displays input", %{conn: conn} do
    {:ok, view, html} = live(conn, "/chat")

    assert html =~ "Type a message"
    assert has_element?(view, "form.chat-input")
    assert has_element?(view, "input[name=\"message\"]")
  end

  test "sending a message appears in transcript", %{conn: conn, room_id: room_id} do
    {:ok, view, _html} = live(conn, "/chat")

    # Subscribe to verify broadcast reaches LiveView
    Room.subscribe(room_id)

    view |> element("form") |> render_submit(%{"message" => "Hello swarm!"})

    Process.sleep(100)
    html = render(view)
    assert html =~ "Hello swarm!"
  end

  test "handles agent streaming events", %{conn: conn, room_id: room_id} do
    {:ok, view, _html} = live(conn, "/chat")

    # Simulate streaming deltas — complete line commits to transcript
    send(view.pid, {:agent_streaming, room_id, "agents/scout", "Hello world\n"})
    Process.sleep(50)

    html = render(view)
    assert html =~ "Hello world"
  end

  test "handles agent message (finalize stream)", %{conn: conn, room_id: room_id} do
    {:ok, view, _html} = live(conn, "/chat")

    # Stream some text without a newline (stays in buffer)
    send(view.pid, {:agent_streaming, room_id, "agents/scout", "partial text"})

    # Finalize — flushes the buffer
    msg = %{
      sender: %{type: :agent, id: "agents/scout", name: "Scout"},
      content: "full response"
    }

    send(view.pid, {:agent_message, msg})
    Process.sleep(50)

    html = render(view)
    assert html =~ "partial text"
  end

  test "handles tool call events", %{conn: conn, room_id: room_id} do
    {:ok, view, _html} = live(conn, "/chat")

    send(view.pid, {:agent_tool_call, room_id, "agents/scout", "egghead_search", %{query: "foo"}})
    Process.sleep(50)

    html = render(view)
    assert html =~ "egghead_search"
  end

  test "handles budget_exhausted and continued", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/chat")

    send(view.pid, :budget_exhausted)
    Process.sleep(50)
    assert render(view) =~ "Budget exhausted"

    send(view.pid, :continued)
    Process.sleep(50)
    refute render(view) =~ "Budget exhausted"
  end

  test "handles agent joined/left", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/chat")

    send(view.pid, {:agent_joined, "agents/scout"})
    Process.sleep(50)
    assert render(view) =~ "Scout joined"

    send(view.pid, {:agent_left, "agents/scout"})
    Process.sleep(50)
    assert render(view) =~ "Scout left"
  end
end
