defmodule Egghead.IRC.SlashVerbsTest do
  @moduledoc """
  Egghead's slash-command palette exposed as native IRC verbs (so
  ERC's `/save`, `/handoff`, `/mute` etc. just work), plus the
  synthesized channel topic and the `/context` snapshot command.

  Most verbs accept either an explicit `#channel` first argument or
  default to the user's only joined channel. Both paths are covered.
  """

  use ExUnit.Case

  alias Egghead.Chat.Room

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

    room_id = "m3-#{:erlang.unique_integer([:positive])}"
    {:ok, _} = Room.start_link(id: room_id)
    on_exit(fn -> if Room.exists?(room_id), do: Room.stop(room_id) end)

    sock = connect(port)
    register(sock, "verbsy")
    send_line(sock, "JOIN ##{room_id}")
    _ = recv_until(sock, "366", 2000)

    {:ok, sock: sock, room_id: room_id, port: port}
  end

  describe "TOPIC on JOIN" do
    test "JOIN gets a 332 RPL_TOPIC and 333 RPL_TOPICWHOTIME", %{room_id: room_id, port: port} do
      sock = connect(port)
      register(sock, "topicwatcher")
      send_line(sock, "JOIN ##{room_id}")

      lines = recv_until(sock, "366 topicwatcher", 2000)
      assert Enum.any?(lines, &String.contains?(&1, "332 topicwatcher ##{room_id}"))
      assert Enum.any?(lines, &String.contains?(&1, "333 topicwatcher ##{room_id}"))
      # Topic body mentions agents (count is 0 in this empty room)
      assert Enum.any?(lines, &String.contains?(&1, "agent"))

      :gen_tcp.close(sock)
    end

    test "agent_joined broadcasts a TOPIC update", %{sock: sock, room_id: room_id} do
      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        Room.topic(room_id),
        {:agent_joined, "agents/scout"}
      )

      # JOIN line first, then TOPIC update.
      first = recv_one(sock, 1500)
      assert first =~ ~r/JOIN ##{room_id}/

      second = recv_one(sock, 1500)
      assert second =~ ~r/TOPIC ##{room_id} :/
    end
  end

  describe "SAVE" do
    test "with no args, SAVE replies with a NOTICE about the result", %{sock: sock} do
      send_line(sock, "SAVE")

      line = recv_one(sock, 2000)
      # The RecordStore isn't running in this test, so save fails — but
      # the important thing is the verb dispatched to the right room
      # and we got a NOTICE response (success or failure shape both
      # start with the server NOTICE prefix).
      assert line =~ ~r/^:test\.irc\.local NOTICE verbsy :Save/
    end
  end

  describe "CONTINUE / HALT" do
    test "CONTINUE in the only joined channel triggers Room.continue", %{
      sock: sock,
      room_id: room_id
    } do
      Phoenix.PubSub.subscribe(Egghead.PubSub, Room.topic(room_id))

      send_line(sock, "CONTINUE")

      assert_receive {:continued, _opts}, 2000
    end

    test "HALT broadcasts :halted", %{sock: sock, room_id: room_id} do
      Phoenix.PubSub.subscribe(Egghead.PubSub, Room.topic(room_id))

      send_line(sock, "HALT")

      assert_receive {:halted, ^room_id}, 2000
    end
  end

  describe "MUTE / UNMUTE" do
    test "MUTE <agent> targets the room's agent and broadcasts :muted_changed", %{
      sock: sock,
      room_id: room_id
    } do
      :ok = Room.join(room_id, "agents/scout")

      Phoenix.PubSub.subscribe(Egghead.PubSub, Room.topic(room_id))
      send_line(sock, "MUTE scout")

      assert_receive {:muted_changed, "agents/scout", true}, 2000
    end

    test "UNMUTE <agent> reverses the mute", %{sock: sock, room_id: room_id} do
      :ok = Room.join(room_id, "agents/scout")
      :ok = Room.mute(room_id, "agents/scout")

      Phoenix.PubSub.subscribe(Egghead.PubSub, Room.topic(room_id))
      send_line(sock, "UNMUTE scout")

      assert_receive {:muted_changed, "agents/scout", false}, 2000
    end

    test "MUTE with unknown nick returns 401 ERR_NOSUCHNICK", %{sock: sock} do
      send_line(sock, "MUTE nobody-here")
      line = recv_one(sock, 1500)
      assert line =~ "401 verbsy nobody-here"
    end
  end

  describe "channel inference" do
    test "verb with no #channel arg in multiple channels yields a NOTICE asking for one", %{
      sock: sock,
      port: port
    } do
      other_id = "m3-other-#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Room.start_link(id: other_id)
      on_exit(fn -> if Room.exists?(other_id), do: Room.stop(other_id) end)

      send_line(sock, "JOIN ##{other_id}")
      _ = recv_until(sock, "366", 2000)

      send_line(sock, "HALT")

      line = recv_one(sock, 1500)
      assert line =~ "NOTICE verbsy :You're in multiple channels"

      _ = port
    end

    test "explicit #channel arg overrides single-channel default", %{
      sock: sock,
      room_id: room_id
    } do
      Phoenix.PubSub.subscribe(Egghead.PubSub, Room.topic(room_id))
      send_line(sock, "HALT ##{room_id}")
      assert_receive {:halted, ^room_id}, 2000
    end
  end

  describe "CONTEXT" do
    test "CONTEXT in an empty room reports no agents", %{sock: sock} do
      send_line(sock, "CONTEXT")
      line = recv_one(sock, 1500)
      assert line =~ "NOTICE verbsy :No agents in this room"
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
end
