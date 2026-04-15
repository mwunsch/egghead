defmodule Egghead.Agent.MCPToolsTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Egghead.Agent.Tools
  alias Egghead.Capability

  @fake_mcp ~s"""
  #!/usr/bin/env bash
  while IFS= read -r line; do
    method=$(printf '%s' "$line" | sed -E 's/.*"method":"([^"]+)".*/\\1/')
    id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')

    case "$method" in
      initialize)
        printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"0.0.1"}}}\\n' "$id"
        ;;
      notifications/initialized) ;;
      tools/list)
        printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"fetch","description":"fetch a URL","inputSchema":{"type":"object","properties":{"url":{"type":"string"}}}}]}}\\n' "$id"
        ;;
      tools/call)
        printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"done"}],"isError":false}}\\n' "$id"
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

    server_name = "fake-#{:erlang.unique_integer([:positive])}"

    server_config = %{
      name: server_name,
      transport: :stdio,
      command: "bash #{script}",
      env: %{},
      headers: %{},
      requires: [
        %Egghead.Capability.Grant{
          resource: :net,
          verb: :get,
          scope: %{hosts: ["api.example.com"]}
        }
      ]
    }

    prev = Application.get_env(:egghead, :mcp_servers, [])
    Application.put_env(:egghead, :mcp_servers, [server_config])
    on_exit(fn -> Application.put_env(:egghead, :mcp_servers, prev) end)

    {:ok, _pid} = Egghead.MCP.Client.Supervisor.start_server(server_config)
    wait_for(fn -> Egghead.MCP.Client.Server.status(server_name) == :ready end)

    {:ok, server_name: server_name}
  end

  describe "definitions_for/1 with MCP servers" do
    test "includes MCP tools when agent grants cover server requires", %{server_name: name} do
      agent_grants =
        Capability.parse([
          %{"net.get" => %{"hosts" => ["*.example.com"]}}
        ])

      defs = Tools.definitions_for(agent_grants)
      mcp_names = Enum.map(defs, & &1.name) |> Enum.filter(&String.starts_with?(&1, "mcp__"))

      expected_name = Tools.mcp_tool_name(name, "fetch")
      assert expected_name in mcp_names
    end

    test "omits MCP tools when agent grants don't cover requires", %{server_name: name} do
      # agent holds net.get but for a different host → not a subset
      agent_grants =
        Capability.parse([
          %{"net.get" => %{"hosts" => ["api.other.com"]}}
        ])

      defs = Tools.definitions_for(agent_grants)
      mcp_names = Enum.map(defs, & &1.name) |> Enum.filter(&String.starts_with?(&1, "mcp__"))

      refute Tools.mcp_tool_name(name, "fetch") in mcp_names
    end

    test "omits MCP tools when agent holds no matching resource at all" do
      agent_grants = Capability.parse(["records.read"])
      defs = Tools.definitions_for(agent_grants)

      assert Enum.all?(defs, &(not String.starts_with?(&1.name, "mcp__")))
    end
  end

  describe "execute/3 with MCP tool names" do
    test "dispatches to MCP.Client.call_tool when authorized", %{server_name: name} do
      agent_grants =
        Capability.parse([
          %{"net.get" => %{"hosts" => ["*.example.com"]}}
        ])

      ctx = %{capabilities: agent_grants, agent_id: "agents/test"}

      assert {:ok, "done"} =
               Tools.execute(Tools.mcp_tool_name(name, "fetch"), %{"url" => "x"}, ctx)
    end

    test "returns a denial when agent grants don't cover server requires", %{server_name: name} do
      agent_grants = Capability.parse(["records.read"])
      ctx = %{capabilities: agent_grants, agent_id: "agents/test"}

      assert {:denied, %Egghead.Capability.Denial{code: :capability_absent}} =
               Tools.execute(Tools.mcp_tool_name(name, "fetch"), %{}, ctx)
    end

    test "returns an error for an mcp__ name whose server is unknown" do
      ctx = %{capabilities: [], agent_id: "agents/test"}
      name = Tools.mcp_tool_name("nobody", "x")
      assert {:error, msg} = Tools.execute(name, %{}, ctx)
      assert msg =~ "not configured"
    end
  end

  describe "parse_mcp_tool_name/1" do
    test "extracts server and tool" do
      assert {:ok, "exa", "web_search"} = Tools.parse_mcp_tool_name("mcp__exa__web_search")
    end

    test "handles tool names containing single underscores" do
      assert {:ok, "gh", "list_repos"} = Tools.parse_mcp_tool_name("mcp__gh__list_repos")
    end

    test "returns :not_mcp for local tool names" do
      assert :not_mcp = Tools.parse_mcp_tool_name("search_records")
    end
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
