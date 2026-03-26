defmodule Egghead.MCP.ServerTest do
  use ExUnit.Case

  # We test the MCP server by simulating stdin/stdout through a port.
  # The server reads JSON-RPC from stdin and writes responses to stdout.

  defp start_mcp_server do
    port =
      Port.open(
        {:spawn, "mix run --no-halt -e 'Egghead.MCP.Server.start()'"},
        [:binary, :use_stdio, {:line, 65_536}]
      )

    # Give the application time to start
    Process.sleep(2000)
    port
  end

  defp send_msg(port, msg) do
    json = Jason.encode!(msg) <> "\n"
    Port.command(port, json)
  end

  defp recv_msg(port, timeout \\ 5000) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        Jason.decode!(line)
    after
      timeout -> raise "Timeout waiting for MCP response"
    end
  end

  defp stop_mcp(port) do
    Port.close(port)
  end

  @tag :mcp_integration
  @tag timeout: 30_000
  test "full MCP protocol handshake and tool calls" do
    port = start_mcp_server()

    try do
      # 1. Initialize
      send_msg(port, %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-03-26",
          capabilities: %{},
          clientInfo: %{name: "test", version: "0.1.0"}
        }
      })

      init_resp = recv_msg(port)
      assert init_resp["id"] == 1
      assert init_resp["result"]["serverInfo"]["name"] == "egghead"
      assert init_resp["result"]["capabilities"]["tools"] == %{}

      # 2. Initialized notification (no response expected)
      send_msg(port, %{jsonrpc: "2.0", method: "notifications/initialized"})

      # 3. List tools
      send_msg(port, %{jsonrpc: "2.0", id: 2, method: "tools/list"})

      tools_resp = recv_msg(port)
      assert tools_resp["id"] == 2
      tool_names = Enum.map(tools_resp["result"]["tools"], & &1["name"]) |> Enum.sort()

      assert tool_names == [
               "egghead_backlinks",
               "egghead_create",
               "egghead_find_links",
               "egghead_get",
               "egghead_list",
               "egghead_recent",
               "egghead_search"
             ]

      # 4. Create a record
      send_msg(port, %{
        jsonrpc: "2.0",
        id: 3,
        method: "tools/call",
        params: %{
          name: "egghead_create",
          arguments: %{
            id: "mcp_test_001",
            title: "MCP Test Record",
            tags: ["mcp", "test"],
            body: "Created via MCP protocol test."
          }
        }
      })

      create_resp = recv_msg(port)
      assert create_resp["id"] == 3
      assert create_resp["result"]["isError"] == false
      assert create_resp["result"]["content"] |> hd() |> Map.get("text") =~ "mcp_test_001"

      # 5. Get the record back
      send_msg(port, %{
        jsonrpc: "2.0",
        id: 4,
        method: "tools/call",
        params: %{
          name: "egghead_get",
          arguments: %{id: "mcp_test_001"}
        }
      })

      get_resp = recv_msg(port)
      assert get_resp["id"] == 4
      text = get_resp["result"]["content"] |> hd() |> Map.get("text")
      assert text =~ "MCP Test Record"
      assert text =~ "Created via MCP protocol test"

      # 6. Search for it
      send_msg(port, %{
        jsonrpc: "2.0",
        id: 5,
        method: "tools/call",
        params: %{
          name: "egghead_search",
          arguments: %{query: "MCP protocol"}
        }
      })

      search_resp = recv_msg(port)
      assert search_resp["id"] == 5
      assert search_resp["result"]["content"] |> hd() |> Map.get("text") =~ "mcp_test_001"

      # 7. List by tag
      send_msg(port, %{
        jsonrpc: "2.0",
        id: 6,
        method: "tools/call",
        params: %{
          name: "egghead_list",
          arguments: %{tag: "mcp"}
        }
      })

      list_resp = recv_msg(port)
      assert list_resp["id"] == 6
      assert list_resp["result"]["content"] |> hd() |> Map.get("text") =~ "mcp_test_001"

      # 8. Ping
      send_msg(port, %{jsonrpc: "2.0", id: 7, method: "ping"})
      ping_resp = recv_msg(port)
      assert ping_resp["id"] == 7
      assert ping_resp["result"] == %{}
    after
      stop_mcp(port)
      # Clean up test record
      File.rm(Path.join("records", "mcp_test_001.md"))
    end
  end
end
