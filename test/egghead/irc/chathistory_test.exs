defmodule Egghead.IRC.ChathistoryTest do
  @moduledoc """
  IRCv3 `chathistory` extension. Five subcommands (LATEST, BEFORE,
  AFTER, AROUND, BETWEEN) for fetching arbitrary windows of room
  history on demand. Responses come BATCH-wrapped with `chathistory`
  type so clients can distinguish historical from live traffic.

  All tests open a connection that has negotiated `server-time`,
  `batch`, and `chathistory` so the server emits the timestamps and
  batch envelope. The complementary path (no caps → no special
  handling) isn't tested separately because CHATHISTORY without
  server-time + batch isn't a meaningful IRCv3 request.
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

    room_id = "ch-#{:erlang.unique_integer([:positive])}"
    {:ok, _} = Room.start_link(id: room_id)
    on_exit(fn -> if Room.exists?(room_id), do: Room.stop(room_id) end)

    seed_transcript(room_id, ["one", "two", "three", "four", "five"])
    {:ok, room_id: room_id, port: port}
  end

  describe "registration advertising" do
    test "ISUPPORT 005 includes CHATHISTORY=<n>", %{port: port} do
      # Plain registration — `open_with_caps/2` would consume the 005
      # line itself, so we drive NICK/USER directly and inspect the
      # welcome burst here.
      sock = connect(port)
      send_line(sock, "NICK isuptest")
      send_line(sock, "USER isuptest 0 * :isuptest")

      lines = recv_until(sock, " 005 isuptest", 2000)

      assert Enum.any?(lines, &String.contains?(&1, "CHATHISTORY=")),
             "ISUPPORT must advertise CHATHISTORY (got: #{inspect(lines)})"

      :gen_tcp.close(sock)
    end

    test "CAP LS advertises chathistory and batch", %{port: port} do
      sock = connect(port)
      send_line(sock, "CAP LS 302")
      line = recv_one(sock, 1500)
      assert line =~ "chathistory"
      assert line =~ "batch"
      :gen_tcp.close(sock)
    end
  end

  describe "CHATHISTORY LATEST" do
    test "wraps response in a BATCH and returns the latest N messages", %{
      port: port,
      room_id: room_id
    } do
      sock = open_with_caps(port, "lateaster")

      send_line(sock, "CHATHISTORY LATEST ##{room_id} * 3")
      lines = drain_batch(sock, 1500)

      open = Enum.find(lines, &String.starts_with?(&1, ":test.irc.local BATCH +"))
      close = Enum.find(lines, &(&1 =~ ~r/^:test\.irc\.local BATCH -/))
      assert open, "expected BATCH open line, got: #{inspect(lines)}"
      assert close, "expected BATCH close line"
      assert open =~ "chathistory ##{room_id}"

      msg_lines = Enum.filter(lines, &String.contains?(&1, "PRIVMSG"))
      assert length(msg_lines) == 3
      # Latest 3 of [one, two, three, four, five] are three/four/five.
      assert Enum.any?(msg_lines, &String.contains?(&1, "three"))
      assert Enum.any?(msg_lines, &String.contains?(&1, "four"))
      assert Enum.any?(msg_lines, &String.contains?(&1, "five"))
      refute Enum.any?(msg_lines, &String.contains?(&1, "one"))

      assert Enum.all?(msg_lines, &String.starts_with?(&1, "@"))
      assert Enum.all?(msg_lines, &String.contains?(&1, "batch="))
      assert Enum.all?(msg_lines, &String.contains?(&1, "time="))

      :gen_tcp.close(sock)
    end

    test "limit is clamped to CHATHISTORY=<max>", %{port: port, room_id: room_id} do
      sock = open_with_caps(port, "clampy")

      # Ask for 10000; we only have 5 in the seed and the cap is 100.
      send_line(sock, "CHATHISTORY LATEST ##{room_id} * 10000")
      lines = drain_batch(sock, 1500)
      msg_lines = Enum.filter(lines, &String.contains?(&1, "PRIVMSG"))
      assert length(msg_lines) == 5

      :gen_tcp.close(sock)
    end
  end

  describe "CHATHISTORY BEFORE / AFTER" do
    test "BEFORE returns messages strictly before timestamp", %{port: port, room_id: room_id} do
      sock = open_with_caps(port, "beforey")

      # Pull all messages so we can identify a pivot timestamp.
      send_line(sock, "CHATHISTORY LATEST ##{room_id} * 100")
      latest = drain_batch(sock, 1500)
      pivot_ts = extract_time_tag(Enum.at(Enum.filter(latest, &String.contains?(&1, "three")), 0))

      send_line(sock, "CHATHISTORY BEFORE ##{room_id} timestamp=#{pivot_ts} 10")
      before_lines = drain_batch(sock, 1500) |> Enum.filter(&String.contains?(&1, "PRIVMSG"))

      # "three" itself is NOT before its own timestamp (strictly less than)
      refute Enum.any?(before_lines, &String.contains?(&1, "three"))
      assert Enum.any?(before_lines, &String.contains?(&1, "one"))
      assert Enum.any?(before_lines, &String.contains?(&1, "two"))

      :gen_tcp.close(sock)
    end

    test "AFTER returns messages strictly after timestamp", %{port: port, room_id: room_id} do
      sock = open_with_caps(port, "aftery")

      send_line(sock, "CHATHISTORY LATEST ##{room_id} * 100")
      latest = drain_batch(sock, 1500)
      pivot_ts = extract_time_tag(Enum.at(Enum.filter(latest, &String.contains?(&1, "three")), 0))

      send_line(sock, "CHATHISTORY AFTER ##{room_id} timestamp=#{pivot_ts} 10")
      after_lines = drain_batch(sock, 1500) |> Enum.filter(&String.contains?(&1, "PRIVMSG"))

      refute Enum.any?(after_lines, &String.contains?(&1, "three"))
      assert Enum.any?(after_lines, &String.contains?(&1, "four"))
      assert Enum.any?(after_lines, &String.contains?(&1, "five"))

      :gen_tcp.close(sock)
    end
  end

  describe "error paths" do
    test "missing subcommand FAILs with NEED_MORE_PARAMS", %{port: port} do
      sock = open_with_caps(port, "errsubcmd")
      send_line(sock, "CHATHISTORY")
      line = recv_one(sock, 1500)
      assert line =~ "FAIL CHATHISTORY NEED_MORE_PARAMS"
      :gen_tcp.close(sock)
    end

    test "unknown subcommand FAILs", %{port: port, room_id: room_id} do
      sock = open_with_caps(port, "errsub")
      send_line(sock, "CHATHISTORY EVERYTHING ##{room_id} * 5")
      line = recv_one(sock, 1500)
      assert line =~ "FAIL CHATHISTORY UNKNOWN_COMMAND"
      :gen_tcp.close(sock)
    end

    test "BEFORE with malformed timestamp FAILs with INVALID_PARAMS", %{
      port: port,
      room_id: room_id
    } do
      sock = open_with_caps(port, "errts")
      send_line(sock, "CHATHISTORY BEFORE ##{room_id} not-a-timestamp 5")
      line = recv_one(sock, 1500)
      assert line =~ "FAIL CHATHISTORY INVALID_PARAMS"
      :gen_tcp.close(sock)
    end

    test "unknown channel FAILs with INVALID_TARGET", %{port: port} do
      sock = open_with_caps(port, "errchan")
      send_line(sock, "CHATHISTORY LATEST #nonexistent-channel * 5")
      line = recv_one(sock, 1500)
      assert line =~ "FAIL CHATHISTORY INVALID_TARGET"
      :gen_tcp.close(sock)
    end
  end

  # --- helpers ---

  defp seed_transcript(room_id, contents) do
    Enum.each(contents, fn c ->
      :ok = Room.send_message(room_id, c)
      # Tiny sleep so each message has a distinct timestamp — needed for
      # the BEFORE/AFTER tests to pivot reliably.
      :timer.sleep(5)
    end)
  end

  defp extract_time_tag(nil), do: raise("expected a timestamped line")

  defp extract_time_tag(line) do
    case Regex.run(~r/time=([^;\s]+)/, line) do
      [_, ts] -> ts
      _ -> raise "no @time tag in: #{inspect(line)}"
    end
  end

  defp drain_batch(sock, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_drain_batch(sock, deadline, [])
  end

  defp do_drain_batch(sock, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 1)

    case :gen_tcp.recv(sock, 0, remaining) do
      {:ok, data} ->
        line = String.trim_trailing(data, "\r\n")
        new_acc = [line | acc]

        if line =~ ~r/^:test\.irc\.local BATCH -/ do
          Enum.reverse(new_acc)
        else
          do_drain_batch(sock, deadline, new_acc)
        end

      {:error, _} ->
        Enum.reverse(acc)
    end
  end

  defp open_with_caps(port, nick) do
    sock = connect(port)
    send_line(sock, "CAP LS 302")
    _ = recv_one(sock, 1500)
    send_line(sock, "CAP REQ :server-time batch chathistory")
    _ = recv_one(sock, 1500)
    send_line(sock, "CAP END")
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

  defp free_port do
    {:ok, l} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(l)
    :gen_tcp.close(l)
    port
  end
end
