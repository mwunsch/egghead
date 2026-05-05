defmodule Egghead.IRC.ActionEventsTest do
  @moduledoc """
  Agent action events surfaced over IRC. Each test drives the room
  directly via PubSub broadcasts (the actual coordinator/agent path is
  too heavy to spin up here) and asserts the IRC connection translates
  to the right wire shape: CTCP ACTION for /pass, tool calls, and tool
  denials; NOTICE for system notices and halt/continue; synthetic
  JOIN/PART for agent roster changes; paragraph-buffered PRIVMSG for
  mid-stream flushes.

  Setup mirrors `server_integration_test.exs` — boot the IRC.Server on
  an OS-assigned port, connect via `:gen_tcp`, register, JOIN a room.
  Then send the room a PubSub event and assert the wire output.
  """

  use ExUnit.Case

  alias Egghead.Chat.Room

  @ctcp_action_marker <<1>> <> "ACTION "

  setup_all do
    case Phoenix.PubSub.Supervisor.start_link(name: Egghead.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  setup do
    port = free_port()

    opts = [
      config: %{
        port: port,
        bind: "127.0.0.1",
        hostname: "test.irc.local",
        password: nil
      }
    ]

    start_supervised!({Egghead.IRC.Server, opts})

    room_id = "m2-#{:erlang.unique_integer([:positive])}"
    {:ok, _} = Room.start_link(id: room_id)
    on_exit(fn -> if Room.exists?(room_id), do: Room.stop(room_id) end)

    sock = connect(port)
    register(sock, "watcher")
    send_line(sock, "JOIN ##{room_id}")
    _ = recv_until(sock, "366", 2000)

    {:ok, sock: sock, room_id: room_id, port: port}
  end

  describe "/pass" do
    test "agent_passed broadcast becomes CTCP ACTION", %{sock: sock, room_id: room_id} do
      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        Room.topic(room_id),
        {:agent_passed, "agents/scout"}
      )

      line = recv_one(sock, 1500)
      assert line =~ ~r/^:scout PRIVMSG ##{room_id} :/
      assert line =~ "\x01ACTION "
      assert String.ends_with?(line, "\x01")
    end
  end

  describe "tool calls" do
    test "agent_tool_call becomes CTCP ACTION with key=value summary", %{
      sock: sock,
      room_id: room_id
    } do
      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        Room.topic(room_id),
        {:agent_tool_call, room_id, "agents/scout", "read_file", %{"path" => "/tmp/foo.md"}}
      )

      line = recv_one(sock, 1500)
      assert line =~ "ACTION uses read_file"
      assert line =~ "path=/tmp/foo.md"
    end

    test "long tool input values are truncated", %{sock: sock, room_id: room_id} do
      long = String.duplicate("a", 80)

      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        Room.topic(room_id),
        {:agent_tool_call, room_id, "agents/scout", "search", %{"query" => long}}
      )

      line = recv_one(sock, 1500)
      assert line =~ "query="
      assert line =~ "..."
      # 40-char limit: 37 chars + "..." prefix is fine
      refute line =~ String.duplicate("a", 50)
    end

    test "empty tool input renders just the verb", %{sock: sock, room_id: room_id} do
      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        Room.topic(room_id),
        {:agent_tool_call, room_id, "agents/scout", "list", %{}}
      )

      line = recv_one(sock, 1500)
      assert line =~ "ACTION uses list\x01"
    end
  end

  describe "tool denials" do
    test "agent_tool_denied becomes CTCP ACTION with the denial message", %{
      sock: sock,
      room_id: room_id
    } do
      denial = %Egghead.Capability.Denial{
        code: :no_grant,
        agent_id: "agents/scout",
        tool: "net_get",
        message: "no grant for net.get on api.example.com",
        held: []
      }

      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        Room.topic(room_id),
        {:agent_tool_denied, room_id, "agents/scout", "net_get", %{"url" => "..."}, denial}
      )

      line = recv_one(sock, 1500)
      assert line =~ ~r/^:scout PRIVMSG ##{room_id} :/
      assert line =~ "ACTION was denied net_get"
      assert line =~ "no grant for net.get on api.example.com"
    end

    test "denial with nil/missing message falls back to a generic reason", %{
      sock: sock,
      room_id: room_id
    } do
      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        Room.topic(room_id),
        {:agent_tool_denied, room_id, "agents/scout", "tool", %{}, nil}
      )

      line = recv_one(sock, 1500)
      assert line =~ "ACTION was denied tool: denied"
    end
  end

  describe "agent join/leave" do
    test "agent_joined broadcasts a synthetic JOIN line for the agent", %{
      sock: sock,
      room_id: room_id
    } do
      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        Room.topic(room_id),
        {:agent_joined, "agents/scout"}
      )

      line = recv_one(sock, 1500)
      assert line =~ ~r/^:scout!egghead@test\.irc\.local JOIN ##{room_id}/
    end

    test "agent_left broadcasts a synthetic PART", %{sock: sock, room_id: room_id} do
      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        Room.topic(room_id),
        {:agent_left, "agents/scout"}
      )

      line = recv_one(sock, 1500)
      assert line =~ ~r/^:scout!egghead@test\.irc\.local PART ##{room_id}/
    end
  end

  describe "system messages" do
    test "system_notice becomes IRC NOTICE", %{sock: sock, room_id: room_id} do
      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        Room.topic(room_id),
        {:system_notice, "Scout muted"}
      )

      line = recv_one(sock, 1500)
      assert line =~ ~r/^:test\.irc\.local NOTICE ##{room_id} :Scout muted/
    end

    test "multiline system_notice splits into multiple NOTICEs", %{sock: sock, room_id: room_id} do
      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        Room.topic(room_id),
        {:system_notice, "first line\nsecond line"}
      )

      l1 = recv_one(sock, 1500)
      l2 = recv_one(sock, 1500)
      assert l1 =~ ":first line"
      assert l2 =~ ":second line"
    end

    test "halted broadcasts a NOTICE", %{sock: sock, room_id: room_id} do
      Phoenix.PubSub.broadcast(Egghead.PubSub, Room.topic(room_id), {:halted, room_id})

      line = recv_one(sock, 1500)
      assert line =~ "NOTICE ##{room_id} :Halted"
    end

    test "continued with replays broadcasts a NOTICE", %{sock: sock, room_id: room_id} do
      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        Room.topic(room_id),
        {:continued, replayed: 3}
      )

      line = recv_one(sock, 1500)
      assert line =~ "NOTICE ##{room_id} :Continuing"
      assert line =~ "3 queued"
    end
  end

  describe "streaming buffer" do
    test "delta without paragraph break does not emit", %{sock: sock, room_id: room_id} do
      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        Room.topic(room_id),
        {:agent_streaming, room_id, "agents/scout", "thinking..."}
      )

      assert {:error, :timeout} = :gen_tcp.recv(sock, 0, 200)
    end

    test "two consecutive deltas with `\\n\\n` flush completed paragraph", %{
      sock: sock,
      room_id: room_id
    } do
      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        Room.topic(room_id),
        {:agent_streaming, room_id, "agents/scout", "Para 1\n\n"}
      )

      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        Room.topic(room_id),
        {:agent_streaming, room_id, "agents/scout", "still typing"}
      )

      line = recv_one(sock, 1500)
      assert line =~ ~r/^:scout PRIVMSG ##{room_id} :Para 1/
      assert {:error, :timeout} = :gen_tcp.recv(sock, 0, 200)
    end

    test "agent_message after a partial stream emits only the unflushed tail", %{
      sock: sock,
      room_id: room_id
    } do
      # Stream "Para 1\n\nPara 2" — paragraph 1 flushes, "Para 2" stays buffered.
      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        Room.topic(room_id),
        {:agent_streaming, room_id, "agents/scout", "Para 1\n\nPara 2"}
      )

      flushed = recv_one(sock, 1500)
      assert flushed =~ ":Para 1"

      # Final message contains the entire content. Tail-only emit should
      # produce just "Para 2".
      msg = %Egghead.Chat.Room.Message{
        id: "msg-test",
        room_id: room_id,
        sender: %Egghead.Chat.Room.Sender{type: :agent, id: "agents/scout", name: "Scout"},
        content: "Para 1\n\nPara 2",
        timestamp: DateTime.utc_now()
      }

      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        Room.topic(room_id),
        {:agent_message, msg}
      )

      tail = recv_one(sock, 1500)
      assert tail =~ ":Para 2"
      refute tail =~ "Para 1"
    end

    test "agent_message with no prior streaming emits the full content", %{
      sock: sock,
      room_id: room_id
    } do
      msg = %Egghead.Chat.Room.Message{
        id: "msg-test-2",
        room_id: room_id,
        sender: %Egghead.Chat.Room.Sender{type: :agent, id: "agents/scout", name: "Scout"},
        content: "Hello there",
        timestamp: DateTime.utc_now()
      }

      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        Room.topic(room_id),
        {:agent_message, msg}
      )

      line = recv_one(sock, 1500)
      assert line =~ ":Hello there"
    end
  end

  describe "multi-room routing" do
    test "events from one room don't leak into another", %{sock: sock, room_id: room_id} do
      other_id = "m2-other-#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Room.start_link(id: other_id)
      on_exit(fn -> if Room.exists?(other_id), do: Room.stop(other_id) end)

      send_line(sock, "JOIN ##{other_id}")
      _ = recv_until(sock, "366", 2000)

      # Broadcast :agent_passed only into `other_id`.
      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        Room.topic(other_id),
        {:agent_passed, "agents/scout"}
      )

      line = recv_one(sock, 1500)
      # Action goes to the right channel.
      assert line =~ ~r/PRIVMSG ##{other_id} /
      refute line =~ ~r/PRIVMSG ##{room_id} /
    end
  end

  # --- helpers ---

  defp connect(port) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line])
    sock
  end

  defp send_line(sock, line) do
    :ok = :gen_tcp.send(sock, [line, "\r\n"])
  end

  defp register(sock, nick) do
    send_line(sock, "NICK #{nick}")
    send_line(sock, "USER #{nick} 0 * :#{nick}")
    _ = recv_until(sock, "005", 2000)
    :ok
  end

  defp recv_one(sock, timeout) do
    {:ok, line} = :gen_tcp.recv(sock, 0, timeout)
    String.trim_trailing(line, "\r\n")
  end

  defp recv_until(sock, marker, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_recv_until(sock, marker, deadline, [])
  end

  defp do_recv_until(sock, marker, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 1)

    case :gen_tcp.recv(sock, 0, remaining) do
      {:ok, data} ->
        line = String.trim_trailing(data, "\r\n")
        acc = [line | acc]
        if line =~ marker, do: Enum.reverse(acc), else: do_recv_until(sock, marker, deadline, acc)

      {:error, _} ->
        Enum.reverse(acc)
    end
  end

  defp free_port do
    {:ok, l} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(l)
    :gen_tcp.close(l)
    port
  end

  # Unused helper retained for symmetry with other test modules.
  _ = @ctcp_action_marker
end
