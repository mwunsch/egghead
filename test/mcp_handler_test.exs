defmodule Egghead.MCP.HandlerTest do
  use ExUnit.Case

  alias Egghead.MCP.Handler

  describe "protocol" do
    test "initialize returns protocol version and capabilities" do
      response =
        Handler.handle(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-03-26",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "test", "version" => "0.1"}
          }
        })

      assert response.jsonrpc == "2.0"
      assert response.id == 1
      assert response.result.protocolVersion == "2025-03-26"
      assert response.result.capabilities.tools == %{}
      assert response.result.serverInfo.name == "egghead"
    end

    test "initialized notification returns :noreply" do
      assert Handler.handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}) ==
               :noreply
    end

    test "ping returns empty result" do
      response = Handler.handle(%{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"})
      assert response.id == 2
      assert response.result == %{}
    end

    test "unknown method returns -32601 error" do
      response = Handler.handle(%{"jsonrpc" => "2.0", "id" => 3, "method" => "bogus/method"})
      assert response.error.code == -32601
      assert response.error.message =~ "Method not found"
    end

    test "notification without id returns :noreply" do
      assert Handler.handle(%{"jsonrpc" => "2.0", "method" => "some/notification"}) == :noreply
    end

    test "malformed message returns :noreply" do
      assert Handler.handle(%{"foo" => "bar"}) == :noreply
    end
  end

  describe "tools/list" do
    test "returns tool definitions with expected tools" do
      response = Handler.handle(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
      tools = response.result.tools
      names = Enum.map(tools, & &1.name)

      assert "egghead_search" in names
      assert "egghead_get" in names
      assert "egghead_list" in names
      assert "egghead_create" in names
      assert "egghead_find_links" in names
      assert "egghead_backlinks" in names
      assert "egghead_recent" in names
      assert "egghead_providers" in names
      assert "egghead_models" in names
      assert "egghead_agents" in names
      assert "egghead_prompt" in names
      assert "egghead_consult" in names

      # Every tool has the required schema fields
      for tool <- tools do
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert tool.inputSchema.type == "object"
      end
    end
  end

  describe "tools/call" do
    test "unknown tool returns error" do
      response =
        Handler.handle(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "egghead_nonexistent_tool",
            "arguments" => %{}
          }
        })

      assert response.result.isError == true
      assert hd(response.result.content).text =~ "Unknown tool"
    end
  end

  describe "tools/call with record store" do
    @tmp_dir Path.join(
               System.tmp_dir!(),
               "egghead_mcp_test_#{:erlang.unique_integer([:positive])}"
             )

    setup do
      File.mkdir_p!(@tmp_dir)
      db_path = Path.join(@tmp_dir, ".egghead/index.db")
      File.mkdir_p!(Path.dirname(db_path))

      start_supervised!({Egghead.RecordSupervisor, records_dir: @tmp_dir, db_path: db_path})
      Process.sleep(200)

      on_exit(fn -> File.rm_rf!(@tmp_dir) end)
      :ok
    end

    test "egghead_create and egghead_get round-trip" do
      # Create a record
      create_response =
        Handler.handle(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "egghead_create",
            "arguments" => %{
              "id" => "mcp-handler-test",
              "title" => "MCP Test Record",
              "body" => "Created via handler test.",
              "tags" => ["test", "mcp"]
            }
          }
        })

      assert create_response.result.isError == false
      assert hd(create_response.result.content).text =~ "Created"

      # Give the file watcher time to index
      Process.sleep(300)

      # Get it back by the explicit ID we set
      get_response =
        Handler.handle(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{
            "name" => "egghead_get",
            "arguments" => %{"id" => "mcp-handler-test"}
          }
        })

      assert get_response.result.isError == false
      assert hd(get_response.result.content).text =~ "Created via handler test"
    end

    test "egghead_get with nonexistent record returns error" do
      response =
        Handler.handle(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "egghead_get",
            "arguments" => %{"id" => "does-not-exist"}
          }
        })

      assert response.result.isError == true
    end

    test "egghead_list returns records" do
      response =
        Handler.handle(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "egghead_list",
            "arguments" => %{}
          }
        })

      assert response.result.isError == false
    end

    test "egghead_search returns results" do
      response =
        Handler.handle(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "egghead_search",
            "arguments" => %{"query" => "test"}
          }
        })

      assert response.result.isError == false
    end
  end

  describe "error/3" do
    test "builds a JSON-RPC error response" do
      response = Handler.error(42, -32700, "Parse error")
      assert response.jsonrpc == "2.0"
      assert response.id == 42
      assert response.error.code == -32700
      assert response.error.message == "Parse error"
    end
  end
end
