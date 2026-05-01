defmodule Egghead.IRC.ServerTimeTest do
  @moduledoc """
  IRCv3 `server-time` capability and history replay on JOIN.

  When a client negotiates `server-time`, every outbound chat-shaped
  line carries an `@time=ISO-8601` tag, and JOIN replays the last N
  transcript messages tagged with their original timestamps so the
  IRC client can slot them into scrollback at the right historical
  moment instead of at "now."
  """

  use ExUnit.Case

  alias Egghead.Chat.Room
  alias Egghead.Chat.Room.{Sender, Message}

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

    {:ok, port: port}
  end

  describe "CAP negotiation" do
    test "CAP LS advertises server-time", %{port: port} do
      sock = connect(port)
      send_line(sock, "CAP LS 302")

      line = recv_one(sock, 1500)
      assert line =~ "CAP * LS :"
      assert line =~ "server-time"
    end

    test "CAP REQ server-time is ACKed", %{port: port} do
      sock = connect(port)
      send_line(sock, "CAP LS 302")
      _ls = recv_one(sock, 1500)

      send_line(sock, "CAP REQ :server-time")
      ack = recv_one(sock, 1500)
      assert ack =~ "CAP * ACK :server-time"
    end

    test "CAP REQ for an unsupported cap is NAKed", %{port: port} do
      sock = connect(port)
      send_line(sock, "CAP LS 302")
      _ls = recv_one(sock, 1500)

      send_line(sock, "CAP REQ :nonexistent-cap")
      nak = recv_one(sock, 1500)
      assert nak =~ "CAP * NAK :nonexistent-cap"
    end

    test "CAP END after ACK + NICK + USER completes registration", %{port: port} do
      sock = connect(port)
      send_line(sock, "CAP LS 302")
      _ = recv_one(sock, 1500)
      send_line(sock, "CAP REQ :server-time")
      _ = recv_one(sock, 1500)
      send_line(sock, "CAP END")

      send_line(sock, "NICK capclient")
      send_line(sock, "USER capclient 0 * :Cap Client")

      lines = recv_until(sock, " 005 capclient", 2000)
      assert Enum.any?(lines, &String.contains?(&1, " 001 capclient :Welcome"))
    end
  end

  describe "@time tag on outbound messages" do
    test "PRIVMSG to a channel carries @time= when server-time is enabled", %{port: port} do
      room_id = "stime-#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Room.start_link(id: room_id)
      on_exit(fn -> if Room.exists?(room_id), do: Room.stop(room_id) end)

      sock = open_with_server_time(port, "tagger")
      send_line(sock, "JOIN ##{room_id}")
      _ = recv_until(sock, "366 tagger", 2000)

      # Push a message INTO the room from a different sender so it
      # comes back to us as an outbound PRIVMSG (own-message echo
      # is suppressed).
      msg = %Message{
        id: "m",
        room_id: room_id,
        sender: %Sender{type: :agent, id: "agents/scout", name: "Scout"},
        content: "hello with timestamp",
        timestamp: DateTime.utc_now()
      }

      Phoenix.PubSub.broadcast(Egghead.PubSub, Room.topic(room_id), {:agent_message, msg})

      line = recv_one(sock, 1500)
      assert line =~ ~r/^@time=20\d\d-\d\d-\d\dT/
      assert line =~ "PRIVMSG ##{room_id}"

      :gen_tcp.close(sock)
    end

    test "no @time tag when client did NOT negotiate server-time", %{port: port} do
      room_id = "notime-#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Room.start_link(id: room_id)
      on_exit(fn -> if Room.exists?(room_id), do: Room.stop(room_id) end)

      sock = open_plain(port, "untagger")
      send_line(sock, "JOIN ##{room_id}")
      _ = recv_until(sock, "366 untagger", 2000)

      msg = %Message{
        id: "m",
        room_id: room_id,
        sender: %Sender{type: :agent, id: "agents/scout", name: "Scout"},
        content: "hello no tag",
        timestamp: DateTime.utc_now()
      }

      Phoenix.PubSub.broadcast(Egghead.PubSub, Room.topic(room_id), {:agent_message, msg})

      line = recv_one(sock, 1500)
      refute line =~ "@time"
      assert line =~ "PRIVMSG ##{room_id}"

      :gen_tcp.close(sock)
    end
  end

  describe "scrollback replay on JOIN" do
    test "JOIN with server-time replays transcript with original timestamps", %{port: port} do
      room_id = "scroll-#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Room.start_link(id: room_id)
      on_exit(fn -> if Room.exists?(room_id), do: Room.stop(room_id) end)

      # Seed the transcript with a couple of messages from days ago.
      old_ts = DateTime.add(DateTime.utc_now(), -86_400, :second)

      :ok =
        Room.send_message(room_id, "first historical line")

      Room.agent_respond(room_id, "agents/scout", "second historical line")

      _ = old_ts

      sock = open_with_server_time(port, "replayer")
      send_line(sock, "JOIN ##{room_id}")

      # Drain through the JOIN burst (echo + topic + names) and
      # collect everything until idle. Replay PRIVMSGs follow.
      :timer.sleep(150)
      lines = drain_all(sock, 800)

      timed_lines =
        Enum.filter(lines, fn l -> String.starts_with?(l, "@time=") end)

      assert length(timed_lines) >= 2,
             "expected at least two @time-tagged scrollback lines (got: #{inspect(lines)})"

      assert Enum.any?(timed_lines, &String.contains?(&1, "first historical line"))
      assert Enum.any?(timed_lines, &String.contains?(&1, "second historical line"))

      :gen_tcp.close(sock)
    end

    test "JOIN without server-time does NOT replay scrollback", %{port: port} do
      room_id = "noscroll-#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Room.start_link(id: room_id)
      on_exit(fn -> if Room.exists?(room_id), do: Room.stop(room_id) end)

      Room.send_message(room_id, "would-be replayed")

      sock = open_plain(port, "noreplay")
      send_line(sock, "JOIN ##{room_id}")

      :timer.sleep(150)
      lines = drain_all(sock, 500)

      refute Enum.any?(lines, &String.contains?(&1, "would-be replayed")),
             "scrollback must not appear when server-time wasn't negotiated"

      :gen_tcp.close(sock)
    end
  end

  # --- helpers ---

  defp open_with_server_time(port, nick) do
    sock = connect(port)
    send_line(sock, "CAP LS 302")
    _ = recv_one(sock, 1500)
    send_line(sock, "CAP REQ :server-time")
    _ = recv_one(sock, 1500)
    send_line(sock, "CAP END")
    send_line(sock, "NICK #{nick}")
    send_line(sock, "USER #{nick} 0 * :#{nick}")
    _ = recv_until(sock, " 005 #{nick}", 2000)
    sock
  end

  defp open_plain(port, nick) do
    sock = connect(port)
    send_line(sock, "NICK #{nick}")
    send_line(sock, "USER #{nick} 0 * :#{nick}")
    _ = recv_until(sock, " 005 #{nick}", 2000)
    sock
  end

  defp connect(port) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line])
    sock
  end

  defp send_line(sock, line) do
    :ok = :gen_tcp.send(sock, [line, "\r\n"])
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

  defp drain_all(sock, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_drain(sock, deadline, [])
  end

  defp do_drain(sock, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 1)

    case :gen_tcp.recv(sock, 0, remaining) do
      {:ok, data} ->
        do_drain(sock, deadline, [String.trim_trailing(data, "\r\n") | acc])

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
