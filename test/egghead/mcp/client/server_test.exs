defmodule Egghead.MCP.Client.ServerTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Egghead.MCP.Client.Server

  # A fixture that behaves like a minimal MCP server on stdio. It
  # handles `initialize`, `notifications/initialized`, `tools/list`,
  # and `tools/call` with a canned response.
  @fake_mcp ~s"""
  #!/usr/bin/env bash
  while IFS= read -r line; do
    method=$(printf '%s' "$line" | sed -E 's/.*"method":"([^"]+)".*/\\1/')
    id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')

    case "$method" in
      initialize)
        printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"0.0.1"}}}\\n' "$id"
        ;;
      notifications/initialized)
        ;;
      tools/list)
        printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"echo","inputSchema":{"type":"object"}}]}}\\n' "$id"
        ;;
      tools/call)
        printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"called"}],"isError":false}}\\n' "$id"
        ;;
    esac
  done
  """

  setup %{tmp_dir: dir} do
    start_supervised!(Egghead.MCP.Client.Registry)
    start_supervised!(Egghead.MCP.Client.Supervisor)

    script = Path.join(dir, "fake_mcp.sh")
    File.write!(script, @fake_mcp)
    File.chmod!(script, 0o755)

    {:ok, script: script}
  end

  test "reaches :ready after handshake and caches tools", %{script: script} do
    name = "fake-#{:erlang.unique_integer([:positive])}"

    {:ok, _pid} =
      Egghead.MCP.Client.Supervisor.start_server(%{
        name: name,
        transport: :stdio,
        command: "bash #{script}"
      })

    wait_for(fn -> Server.status(name) == :ready end)

    [tool] = Server.tools(name)
    assert tool["name"] == "echo"
  end

  test "call_tool round-trips a tools/call response", %{script: script} do
    name = "fake-call-#{:erlang.unique_integer([:positive])}"

    {:ok, _pid} =
      Egghead.MCP.Client.Supervisor.start_server(%{
        name: name,
        transport: :stdio,
        command: "bash #{script}"
      })

    wait_for(fn -> Server.status(name) == :ready end)

    assert {:ok, "called"} = Server.call_tool(name, "echo", %{hello: "world"})
  end

  test "call_tool on an unknown server returns :error" do
    assert {:error, _} = Server.call_tool("nobody-here", "x", %{})
  end

  defp wait_for(fun, deadline_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    Stream.repeatedly(fn -> :ok end)
    |> Enum.reduce_while(nil, fn _, _ ->
      cond do
        fun.() ->
          {:halt, :ok}

        System.monotonic_time(:millisecond) > deadline ->
          {:halt, :timeout}

        true ->
          Process.sleep(25)
          {:cont, nil}
      end
    end)
  end
end
