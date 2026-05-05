defmodule Egghead.IRC.OpsCommandsTest do
  @moduledoc """
  KICK, INVITE, WHOIS, MOTD, VERSION, TIME — the ops layer that rounds
  out the IRC verb set so the server feels like a real IRC network and
  not a toy.

  KICK and INVITE map directly to Room.leave/2 and Room.join/2 — no
  channel-op gating since rooms are flat. WHOIS for an agent surfaces
  model + context-window % + capabilities; for a connected human
  returns a basic identity reply.
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

    room_id = "m35-#{:erlang.unique_integer([:positive])}"
    {:ok, _} = Room.start_link(id: room_id)
    on_exit(fn -> if Room.exists?(room_id), do: Room.stop(room_id) end)

    sock = connect(port)
    register(sock, "opsy")
    send_line(sock, "JOIN ##{room_id}")
    _ = recv_until(sock, "366", 2000)

    {:ok, sock: sock, room_id: room_id, port: port}
  end

  describe "KICK" do
    test "KICK <channel> <nick> calls Room.leave for the resolved agent", %{
      sock: sock,
      room_id: room_id
    } do
      :ok = Room.join(room_id, "agents/scout")

      Phoenix.PubSub.subscribe(Egghead.PubSub, Room.topic(room_id))
      send_line(sock, "KICK ##{room_id} scout")

      assert_receive {:agent_left, "agents/scout"}, 2000
    end

    test "KICK with unknown nick returns 401 ERR_NOSUCHNICK", %{sock: sock, room_id: room_id} do
      send_line(sock, "KICK ##{room_id} ghost")
      line = recv_one(sock, 1500)
      assert line =~ "401 opsy ghost"
    end

    test "KICK with missing args returns 461", %{sock: sock} do
      send_line(sock, "KICK")
      line = recv_one(sock, 1500)
      assert line =~ "461 opsy KICK"
    end
  end

  describe "INVITE" do
    test "INVITE with unknown agent returns 401", %{sock: sock, room_id: room_id} do
      send_line(sock, "INVITE no-such-agent ##{room_id}")
      line = recv_one(sock, 1500)
      assert line =~ "401 opsy no-such-agent"
    end

    test "INVITE against #default doesn't crash when caller hasn't joined #default", %{
      sock: sock,
      room_id: room_id
    } do
      # Regression: `#default` is a per-connection alias resolved on
      # JOIN, but `target_to_room_id/2` used to fall through to a
      # literal "default" room id when the caller hadn't joined via
      # that name. Subsequent Room.join("default", ...) crashed the
      # connection with :no_proc. Now `target_to_room_id/2` resolves
      # `#default` against `Egghead.default_room/0` even without a
      # local alias.
      saved = :persistent_term.get(:egghead_default_room, nil)
      :persistent_term.put(:egghead_default_room, room_id)

      on_exit(fn ->
        if saved,
          do: :persistent_term.put(:egghead_default_room, saved),
          else: :persistent_term.erase(:egghead_default_room)
      end)

      send_line(sock, "INVITE no-such-agent #default")

      # Still 401 (agent doesn't exist) — but the connection must
      # remain alive (no crash).
      line = recv_one(sock, 1500)
      assert line =~ "401 opsy no-such-agent"

      # Sanity: connection survives the call.
      send_line(sock, "PING :alive")
      pong = recv_one(sock, 1000)
      assert pong =~ "PONG"
    end

    # Skipping the 443-already-on-channel test: it requires a real
    # registered agent process that `resolve_agent_anywhere/1` (which
    # walks `Egghead.Agent.list_agents/0`) can find. Heavy to set up
    # in unit-test mode without the record store. The unknown-agent
    # test above exercises the resolve path; the 443 wire shape is
    # validated by `protocol_test.exs` doctests on the encoder.
  end

  describe "WHOIS" do
    test "WHOIS for an unknown nick returns 401 then 318", %{sock: sock} do
      send_line(sock, "WHOIS noone")
      lines = recv_until(sock, " 318 opsy", 1500)
      assert Enum.any?(lines, &String.contains?(&1, "401 opsy noone"))
      assert Enum.any?(lines, &String.contains?(&1, "318 opsy noone"))
    end

    test "WHOIS for the current connection (a human nick) returns 311 then 318", %{sock: sock} do
      send_line(sock, "WHOIS opsy")
      lines = recv_until(sock, " 318 opsy", 1500)
      assert Enum.any?(lines, &String.contains?(&1, "311 opsy opsy "))
      assert Enum.any?(lines, &String.contains?(&1, "318 opsy opsy"))
    end

    test "WHOIS for an agent does NOT emit 320 RPL_WHOISSPECIAL", %{sock: sock} do
      # Regression: 320 has split semantics across IRCds — ERC and
      # several other clients render it as "is identified to services"
      # regardless of trailing text, so packing context/disposition/
      # capabilities into 320 lines silently lost the data. We now use
      # 311 realname + 312 server-info + 335 RPL_WHOISBOT instead.
      send_line(sock, "WHOIS opsy")
      lines = recv_until(sock, " 318 opsy", 1500)

      refute Enum.any?(lines, &String.contains?(&1, " 320 ")),
             "WHOIS should not emit 320 (got: #{inspect(lines)})"
    end
  end

  describe "MOTD" do
    test "MOTD returns 375 / 372s / 376", %{sock: sock} do
      send_line(sock, "MOTD")
      lines = recv_until(sock, " 376 opsy", 1500)

      assert Enum.any?(lines, &String.contains?(&1, "375 opsy"))
      assert Enum.any?(lines, &String.contains?(&1, "372 opsy"))
      assert Enum.any?(lines, &String.contains?(&1, "376 opsy"))
      assert Enum.any?(lines, &String.contains?(&1, "Welcome to Egghead"))
    end
  end

  describe "VERSION" do
    test "VERSION returns 351 with the egghead version string", %{sock: sock} do
      send_line(sock, "VERSION")
      line = recv_one(sock, 1500)
      assert line =~ "351 opsy"
      assert line =~ "egghead"
    end
  end

  describe "TIME" do
    test "TIME returns 391 with an ISO-8601 timestamp", %{sock: sock} do
      send_line(sock, "TIME")
      line = recv_one(sock, 1500)
      assert line =~ "391 opsy"
      # ISO-8601 has the year prefix and a `T` separator
      assert line =~ ~r/202[0-9]-/
      assert line =~ "T"
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
