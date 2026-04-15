defmodule Egghead.CLI.ToolsCmdTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Egghead.CLI.ToolsCmd

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "config.yml")
    previous = System.get_env("EGGHEAD_CONFIG")
    System.put_env("EGGHEAD_CONFIG", path)

    on_exit(fn ->
      if previous,
        do: System.put_env("EGGHEAD_CONFIG", previous),
        else: System.delete_env("EGGHEAD_CONFIG")
    end)

    {:ok, path: path}
  end

  test "--help prints usage" do
    output = capture_io(fn -> ToolsCmd.run(["--help"]) end)
    assert output =~ "egghead tools"
    assert output =~ "mcp list"
    assert output =~ "--agent"
  end

  test "mcp list with no servers configured prints helpful message", %{path: path} do
    File.write!(path, "records_dir: ~/.egghead\n")
    # Make sure app env matches config
    Application.put_env(:egghead, :mcp_servers, [])

    output = capture_io(fn -> ToolsCmd.run(["mcp", "list"]) end)
    assert output =~ "No MCP servers configured"
  end

  test "mcp show on an unknown server errors", %{path: path} do
    File.write!(path, "records_dir: ~/.egghead\n")
    Application.put_env(:egghead, :mcp_servers, [])

    output = capture_io(fn -> ToolsCmd.run(["mcp", "show", "ghost"]) end)
    assert output =~ "No MCP server named"
  end

  test "mcp remove on an unknown server errors", %{path: path} do
    File.write!(path, "records_dir: ~/.egghead\n")
    Application.put_env(:egghead, :mcp_servers, [])

    output = capture_io(fn -> ToolsCmd.run(["mcp", "remove", "ghost"]) end)
    assert output =~ "No MCP server named"
  end

  test "mcp add without name errors" do
    output = capture_io(fn -> ToolsCmd.run(["mcp", "add"]) end)
    assert output =~ "usage:"
  end

  test "mcp add <unknown> without --stdio/--http errors", %{path: path} do
    File.write!(path, "records_dir: ~/.egghead\n")
    Application.put_env(:egghead, :mcp_servers, [])

    output = capture_io(fn -> ToolsCmd.run(["mcp", "add", "definitely-not-in-registry"]) end)
    assert output =~ "not in curated registry"
  end
end
