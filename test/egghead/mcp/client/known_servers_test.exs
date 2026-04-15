defmodule Egghead.MCP.Client.KnownServersTest do
  use ExUnit.Case, async: true

  alias Egghead.MCP.Client.KnownServers

  test "lookup returns a known entry" do
    assert %{"description" => _, "transport" => "stdio"} = KnownServers.lookup("exa")
  end

  test "lookup returns nil for unknown entries" do
    assert KnownServers.lookup("nonexistent-server") == nil
  end

  test "all/0 returns a non-empty registry" do
    assert map_size(KnownServers.all()) > 0
  end

  test "substitute/2 fills <path> placeholders in command and requires_template" do
    spec = KnownServers.lookup("filesystem")
    assert String.contains?(spec["command"], "<path>")

    expanded = KnownServers.substitute(spec, %{"path" => "/Users/m/projects"})

    refute String.contains?(expanded["command"], "<path>")
    assert String.contains?(expanded["command"], "/Users/m/projects")
    assert Map.has_key?(expanded, "requires")
    refute Map.has_key?(expanded, "requires_template")

    [fs_read, _fs_write] = expanded["requires"]
    assert %{"fs.read" => %{"paths" => ["/Users/m/projects/**"]}} = fs_read
  end

  test "substitute/2 leaves non-templated specs alone" do
    spec = KnownServers.lookup("exa")
    expanded = KnownServers.substitute(spec, %{})
    assert expanded["requires"] == spec["requires"]
    assert expanded["command"] == spec["command"]
  end
end
