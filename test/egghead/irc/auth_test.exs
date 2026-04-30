defmodule Egghead.IRC.AuthTest do
  @moduledoc """
  PASS authentication path. Lives in its own test module because it
  needs an `Egghead.IRC.Server` configured with a password — the
  `server_integration_test.exs` setup uses no auth.
  """

  use ExUnit.Case

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
        hostname: "auth.test.local",
        password: "hunter2"
      }
    ]

    start_supervised!({Egghead.IRC.Server, opts})
    {:ok, port: port}
  end

  test "wrong PASS gets 464 and disconnect", ctx do
    sock = connect(ctx.port)
    :ok = :gen_tcp.send(sock, "PASS wrong\r\n")

    {:ok, line} = :gen_tcp.recv(sock, 0, 2000)
    assert line =~ "464"
    assert {:error, :closed} = :gen_tcp.recv(sock, 0, 1000)
  end

  test "correct PASS allows registration", ctx do
    sock = connect(ctx.port)
    :ok = :gen_tcp.send(sock, "PASS hunter2\r\n")
    :ok = :gen_tcp.send(sock, "NICK frank\r\n")
    :ok = :gen_tcp.send(sock, "USER frank 0 * :Frank\r\n")

    welcome = recv_until(sock, "001", 2000)
    assert Enum.any?(welcome, &String.contains?(&1, "001 frank"))

    :gen_tcp.close(sock)
  end

  defp connect(port) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line])
    sock
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
