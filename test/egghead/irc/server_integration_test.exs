defmodule Egghead.IRC.ServerIntegrationTest do
  @moduledoc """
  End-to-end smoke tests against a live IRC listener. Boots the
  `Egghead.IRC.Server` supervision subtree on an OS-assigned port,
  connects via `:gen_tcp`, drives the protocol, and asserts on what
  comes back over the wire.

  This is the M1 acceptance test — the protocol-only unit tests in
  `protocol_test.exs` cover encoding/parsing, but only this test
  proves the registration handshake, JOIN/PART, and PRIVMSG round-trip
  through real sockets.
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

    {:ok, port: port}
  end

  describe "registration handshake" do
    test "NICK + USER yields 001 RPL_WELCOME and ISUPPORT", ctx do
      sock = connect(ctx.port)
      send_line(sock, "NICK alice")
      send_line(sock, "USER alice 0 * :Alice in Tests")

      lines = recv_until(sock, "005", 2000)
      assert Enum.any?(lines, &String.contains?(&1, "001 alice :Welcome"))
      assert Enum.any?(lines, &String.contains?(&1, "002 alice"))
      assert Enum.any?(lines, &String.contains?(&1, "003 alice"))
      assert Enum.any?(lines, &String.contains?(&1, "004 alice"))
      assert Enum.any?(lines, &String.contains?(&1, "005 alice"))

      :gen_tcp.close(sock)
    end

    test "PING/PONG works pre-registration", ctx do
      sock = connect(ctx.port)
      send_line(sock, "PING :probe")
      [line] = recv_lines(sock, 1, 1000)
      assert line =~ ~r/^:test\.irc\.local PONG test\.irc\.local :probe/

      :gen_tcp.close(sock)
    end

    test "duplicate NICK collides with 433 ERR_NICKNAMEINUSE", ctx do
      sock1 = connect(ctx.port)
      register(sock1, "carol")

      sock2 = connect(ctx.port)
      send_line(sock2, "NICK carol")
      send_line(sock2, "USER carol 0 * :Carol")

      lines = recv_lines(sock2, 1, 1000)
      assert Enum.any?(lines, &String.contains?(&1, "433"))
      assert Enum.any?(lines, &String.contains?(&1, "carol"))

      :gen_tcp.close(sock1)
      :gen_tcp.close(sock2)
    end
  end

  describe "channel ops" do
    test "JOIN auto-creates room, echoes JOIN, sends NAMES", ctx do
      room_id = "irc-test-#{:erlang.unique_integer([:positive])}"
      sock = connect(ctx.port)
      register(sock, "bob")

      send_line(sock, "JOIN ##{room_id}")

      lines = recv_until(sock, "366", 2000)

      assert Enum.any?(lines, fn l ->
               l =~ ~r/^:bob![^ ]+ JOIN ##{room_id}/
             end),
             "expected JOIN echo, got: #{inspect(lines)}"

      assert Enum.any?(lines, &String.contains?(&1, "353 bob = ##{room_id}"))
      assert Enum.any?(lines, &String.contains?(&1, "366 bob ##{room_id}"))

      assert Room.exists?(room_id), "room should have been auto-created"

      :gen_tcp.close(sock)
      Room.stop(room_id)
    end

    test "PRIVMSG to channel reaches the Room transcript", ctx do
      room_id = "irc-msg-#{:erlang.unique_integer([:positive])}"
      sock = connect(ctx.port)
      register(sock, "dave")

      send_line(sock, "JOIN ##{room_id}")
      _ = recv_until(sock, "366", 2000)

      Phoenix.PubSub.subscribe(Egghead.PubSub, Room.topic(room_id))

      send_line(sock, "PRIVMSG ##{room_id} :hello room")

      assert_receive {:user_message, msg}, 2000
      assert msg.content == "hello room"
      assert msg.sender.type == :user

      :gen_tcp.close(sock)
      Room.stop(room_id)
    end

    test "QUIT closes the connection cleanly", ctx do
      sock = connect(ctx.port)
      register(sock, "eve")
      send_line(sock, "QUIT :bye")

      # Server should close the socket; reading should hit :closed.
      assert {:error, :closed} = read_until_closed(sock, 1000)
    end

    test "PRIVMSG to channel is NOT echoed back to sender", ctx do
      # Sender's nick must match $USER for this to suppress (see
      # `own_user_message?/2` in Connection — single-user M1 caveat).
      nick = System.get_env("USER") || "user"
      room_id = "no-echo-#{:erlang.unique_integer([:positive])}"

      sock = connect(ctx.port)
      register(sock, nick)
      send_line(sock, "JOIN ##{room_id}")
      _ = recv_until(sock, "366", 2000)

      send_line(sock, "PRIVMSG ##{room_id} :hello echo")

      # No PRIVMSG should come back. Wait a beat to give PubSub time
      # to propagate, then assert no PRIVMSG line is sitting on the
      # socket.
      :timer.sleep(150)

      assert {:error, :timeout} = :gen_tcp.recv(sock, 0, 100),
             "expected no echo, but got something"

      :gen_tcp.close(sock)
      Room.stop(room_id)
    end
  end

  describe "MODE" do
    test "MODE #channel returns 324 channel mode is", ctx do
      room_id = "mode-#{:erlang.unique_integer([:positive])}"
      sock = connect(ctx.port)
      register(sock, "alice")
      send_line(sock, "JOIN ##{room_id}")
      _ = recv_until(sock, "366", 2000)

      send_line(sock, "MODE ##{room_id}")

      lines = recv_lines(sock, 2, 1000)
      assert Enum.any?(lines, &String.contains?(&1, "324 alice ##{room_id} +"))
      assert Enum.any?(lines, &String.contains?(&1, "329 alice ##{room_id}"))

      :gen_tcp.close(sock)
      Room.stop(room_id)
    end

    test "MODE nick returns 221 user mode", ctx do
      sock = connect(ctx.port)
      register(sock, "modetest")

      send_line(sock, "MODE modetest")
      [line] = recv_lines(sock, 1, 1000)
      assert line =~ "221 modetest +"

      :gen_tcp.close(sock)
    end
  end

  describe "LIST" do
    test "LIST with an empty trailing param (ERC's `/list`) returns all rooms", ctx do
      # Regression: ERC and some other clients send `LIST :` (LIST with
      # a `:`-introduced empty trailing param) when the user types
      # /list with no filter. The parser puts that in `trailing` as ""
      # and `Message.args/1` returns `[""]` — not `[]`. Earlier the
      # handler treated `[""]` as a filter set and matched zero rooms.
      room_id = "list-empty-trail-#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Room.start_link(id: room_id)

      sock = connect(ctx.port)
      register(sock, "ercer")

      # Note the `:` — that's the empty trailing param ERC actually sends.
      send_line(sock, "LIST :")

      lines = recv_until(sock, " 323 ercer", 2000)

      assert Enum.any?(lines, &String.contains?(&1, " 322 ercer ##{room_id}")),
             "LIST : should match all rooms (got: #{inspect(lines)})"

      :gen_tcp.close(sock)
      Room.stop(room_id)
    end

    test "LIST returns all running rooms", ctx do
      # Suffix is a fixed string (not the unique-integer counter) so the
      # room id can never accidentally contain a numeric like "323" that
      # collides with the LIST-end marker we recv_until on.
      room_id = "list-room-#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Room.start_link(id: room_id)

      sock = connect(ctx.port)
      register(sock, "lister")

      send_line(sock, "LIST")

      lines = recv_until(sock, " 323 lister", 2000)
      assert Enum.any?(lines, &String.contains?(&1, " 321 lister"))
      assert Enum.any?(lines, &String.contains?(&1, " 322 lister ##{room_id}"))
      assert Enum.any?(lines, &String.contains?(&1, " 323 lister"))

      :gen_tcp.close(sock)
      Room.stop(room_id)
    end

    test "LIST marks the default room with a topic hint", ctx do
      room_id = "list-default-#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Room.start_link(id: room_id)

      saved = :persistent_term.get(:egghead_default_room, nil)
      :persistent_term.put(:egghead_default_room, room_id)

      on_exit(fn ->
        if saved,
          do: :persistent_term.put(:egghead_default_room, saved),
          else: :persistent_term.erase(:egghead_default_room)
      end)

      sock = connect(ctx.port)
      register(sock, "default-lister")

      send_line(sock, "LIST")
      lines = recv_until(sock, " 323 default-lister", 2000)

      entry =
        Enum.find(lines, &String.contains?(&1, " 322 default-lister ##{room_id}"))

      assert entry, "expected 322 RPL_LIST entry for #{room_id}"
      assert entry =~ "Default room"
      assert entry =~ "#default"

      :gen_tcp.close(sock)
      Room.stop(room_id)
    end
  end

  describe "#default alias" do
    setup do
      room_id = "alias-default-#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Room.start_link(id: room_id)

      saved = :persistent_term.get(:egghead_default_room, nil)
      :persistent_term.put(:egghead_default_room, room_id)

      on_exit(fn ->
        if saved,
          do: :persistent_term.put(:egghead_default_room, saved),
          else: :persistent_term.erase(:egghead_default_room)

        if Room.exists?(room_id), do: Room.stop(room_id)
      end)

      {:ok, room_id: room_id}
    end

    test "JOIN #default echoes the alias name (so strict clients open the right buffer)", ctx do
      sock = connect(ctx.port)
      register(sock, "aliaser")

      send_line(sock, "JOIN #default")
      lines = recv_until(sock, "366 aliaser", 2000)

      # Strict clients (ERC) only open a channel buffer when the JOIN
      # echo references the channel they asked for. Echoing the
      # canonical name silently fails — the buffer is never created.
      assert Enum.any?(lines, fn l ->
               l =~ ~r/^:aliaser![^ ]+ JOIN #default/
             end),
             "JOIN echo must use #default (the typed name), not canonical. got: #{inspect(lines)}"

      assert Enum.any?(lines, &String.contains?(&1, "353 aliaser = #default")),
             "NAMES reply must reference #default too"

      :gen_tcp.close(sock)
    end

    test "PRIVMSG #default routes to the canonical room", ctx do
      sock = connect(ctx.port)
      register(sock, "talker")

      send_line(sock, "JOIN #default")
      _ = recv_until(sock, "366 talker", 2000)

      Phoenix.PubSub.subscribe(Egghead.PubSub, Room.topic(ctx.room_id))

      send_line(sock, "PRIVMSG #default :hello via alias")

      assert_receive {:user_message, msg}, 2000
      assert msg.content == "hello via alias"
      assert msg.room_id == ctx.room_id

      :gen_tcp.close(sock)
    end

    test "agent events on the canonical room arrive as #default", ctx do
      sock = connect(ctx.port)
      register(sock, "watcher")

      send_line(sock, "JOIN #default")
      _ = recv_until(sock, "366 watcher", 2000)

      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        Room.topic(ctx.room_id),
        {:agent_passed, "agents/scout"}
      )

      {:ok, line} = :gen_tcp.recv(sock, 0, 2000)
      assert String.trim_trailing(line, "\r\n") =~ "PRIVMSG #default :"

      :gen_tcp.close(sock)
    end

    test "PART #default echoes #default and tears down the alias", ctx do
      sock = connect(ctx.port)
      register(sock, "leaver")

      send_line(sock, "JOIN #default")
      _ = recv_until(sock, "366 leaver", 2000)

      send_line(sock, "PART #default")
      {:ok, line} = :gen_tcp.recv(sock, 0, 2000)
      assert String.trim_trailing(line, "\r\n") =~ ~r/^:leaver![^ ]+ PART #default/

      :gen_tcp.close(sock)
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

  defp recv_lines(sock, n, timeout) do
    Enum.map(1..n, fn _ ->
      {:ok, line} = :gen_tcp.recv(sock, 0, timeout)
      String.trim_trailing(line, "\r\n")
    end)
  end

  # Read lines until one of them contains the given numeric, then return
  # the accumulated list (including the matching line). Stops on timeout.
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

        if line =~ marker do
          Enum.reverse(acc)
        else
          do_recv_until(sock, marker, deadline, acc)
        end

      {:error, _} ->
        Enum.reverse(acc)
    end
  end

  defp read_until_closed(sock, timeout) do
    case :gen_tcp.recv(sock, 0, timeout) do
      {:ok, _} -> read_until_closed(sock, timeout)
      {:error, :closed} -> {:error, :closed}
      {:error, _} = err -> err
    end
  end

  defp free_port do
    {:ok, l} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(l)
    :gen_tcp.close(l)
    port
  end
end
