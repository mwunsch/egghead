defmodule Egghead.ConfigMCPTest do
  use ExUnit.Case, async: false

  alias Egghead.Config

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

  test "parses mcp_servers from YAML", %{path: path} do
    File.write!(path, """
    records_dir: ~/.egghead
    mcp_servers:
      - name: exa
        transport: stdio
        command: "npx -y exa-mcp-server"
        env:
          EXA_API_KEY: "{env:EXA_API_KEY}"
        requires:
          - net.get:
              hosts: ["api.exa.ai"]
      - name: local-gh
        transport: stdio
        command: "mcp-github"
        requires:
          - net.get:
              hosts: ["api.github.com"]
          - net.post:
              hosts: ["api.github.com"]
    """)

    {:ok, config} = Config.load()

    assert [exa, gh] = config.mcp_servers
    assert exa.name == "exa"
    assert exa.transport == :stdio
    assert exa.command == "npx -y exa-mcp-server"
    assert exa.env == %{"EXA_API_KEY" => "{env:EXA_API_KEY}"}

    [%Egghead.Capability.Grant{resource: :net, verb: :get, scope: scope}] = exa.requires
    assert scope.hosts == ["api.exa.ai"]

    assert gh.name == "local-gh"
    assert length(gh.requires) == 2
  end

  test "absent mcp_servers defaults to empty list", %{path: path} do
    File.write!(path, "records_dir: ~/.egghead\n")
    {:ok, config} = Config.load()
    assert config.mcp_servers == []
  end

  test "round-trips mcp_servers through save/load", %{path: path} do
    File.write!(path, """
    records_dir: ~/.egghead
    mcp_servers:
      - name: egghead-self
        transport: stdio
        command: "egghead mcp"
        requires:
          - records.read
          - records.create
    """)

    {:ok, original} = Config.load()
    :ok = Config.save(original)
    {:ok, reloaded} = Config.load()

    assert original.mcp_servers == reloaded.mcp_servers
  end
end
