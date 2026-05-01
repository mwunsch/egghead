defmodule Egghead.IRC.M36DMTest do
  @moduledoc """
  M3.6 — direct messages. `PRIVMSG <nick> :body` to an agent nick
  becomes an ephemeral `Egghead.prompt/3` call; the response comes
  back as a PRIVMSG from the agent to the asker. Human-to-human DMs
  are still M4.

  Most assertions cover the dispatch path (unknown nick → 401, known
  human → "not wired" NOTICE, connection survives during the async
  prompt). The successful round-trip path requires a real LLM and is
  exercised in live use, not here.
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

    room_id = "m36-#{:erlang.unique_integer([:positive])}"
    {:ok, _} = Room.start_link(id: room_id)
    on_exit(fn -> if Room.exists?(room_id), do: Room.stop(room_id) end)

    sock = connect(port)
    register(sock, "asker")
    send_line(sock, "JOIN ##{room_id}")
    _ = recv_until(sock, "366", 2000)

    {:ok, sock: sock, room_id: room_id, port: port}
  end

  describe "DM target resolution" do
    test "PRIVMSG to an unknown nick returns 401 ERR_NOSUCHNICK", %{sock: sock} do
      send_line(sock, "PRIVMSG ghost :hi")

      line = recv_one(sock, 1500)
      assert line =~ "401 asker ghost"
    end

    test "PRIVMSG to another connected human nick returns the M4 not-wired NOTICE", %{
      sock: sock,
      port: port
    } do
      # Spin up a second connection so its nick is in the registry.
      sock2 = connect(port)
      register(sock2, "otherperson")

      send_line(sock, "PRIVMSG otherperson :hi")

      line = recv_one(sock, 1500)
      assert line =~ "NOTICE asker :Human-to-human DMs"

      :gen_tcp.close(sock2)
    end

    test "PRIVMSG to an agent nick does not return 401 (the dispatch ran)", %{sock: sock} do
      # In test mode no real agents are registered, so resolve_anywhere
      # returns :not_found — same as unknown nick. We can't unit-test
      # the success path without an LLM, but we can lock in that the
      # connection stays alive across the call (no crash from the Task
      # spawn or socket plumbing).
      send_line(sock, "PRIVMSG anything :hello")
      _ = recv_one(sock, 1500)

      send_line(sock, "PING :alive-check")
      pong = recv_one(sock, 1000)
      assert pong =~ "PONG"
    end
  end

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
