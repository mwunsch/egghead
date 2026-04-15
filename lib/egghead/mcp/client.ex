defmodule Egghead.MCP.Client do
  @moduledoc """
  Public facade for MCP client functionality.

  Configured servers declared in `~/.config/egghead/config.yml` under
  `mcp_servers:` are spawned at application start (see
  `Egghead.Application`). Each server has a `Server` GenServer owning
  its transport, a tool-list cache, and a handshake state machine.

  Agents use MCP tools via the capability system: each server declares
  `requires:` — the effective capabilities the agent takes on by using
  it — and tools from a server are only offered to agents whose grants
  cover that `requires` set. No new `mcp.*` capability verb; MCP tools
  compose with the existing vocabulary.

  ## Usage

      # List configured server names
      Egghead.MCP.Client.servers()

      # Get the cached tool list from a server
      Egghead.MCP.Client.tools_for("exa")

      # Invoke a tool
      Egghead.MCP.Client.call_tool("exa", "web_search", %{query: "..."})
  """

  alias Egghead.MCP.Client.Server

  @doc "Names of all configured MCP servers (running or stopped)."
  def servers do
    Application.get_env(:egghead, :mcp_servers, [])
    |> Enum.map(& &1.name)
  end

  @doc "Config map for a single server, or `nil` if unknown."
  def config_for(name) do
    Application.get_env(:egghead, :mcp_servers, [])
    |> Enum.find(&(&1.name == name))
  end

  @doc "Running status of every configured server."
  def status do
    Enum.map(servers(), fn name ->
      {name, Server.status(name)}
    end)
  end

  @doc "Cached tool list for a server. Empty if unreachable."
  def tools_for(name), do: Server.tools(name)

  @doc "Invoke a tool on a server. Blocks until reply or timeout."
  def call_tool(name, tool, input, opts \\ []),
    do: Server.call_tool(name, tool, input, opts)

  @doc """
  Agents eligible to use a given server — those whose grants cover
  the server's `requires`. Used by the CLI `tools mcp show / who`
  subcommands and the TUI overlays.
  """
  def eligible_agents(server_name) do
    case config_for(server_name) do
      nil ->
        []

      %{requires: required_grants} ->
        Egghead.list_agents()
        |> Enum.filter(fn agent ->
          # agent.capabilities is already a list of %Grant{} structs
          # (parsed on agent start). Don't re-parse — Capability.parse/1
          # expects raw frontmatter values (strings/maps), not Grants,
          # and silently drops anything that doesn't match.
          held = agent[:capabilities] || []
          Egghead.Capability.subset?(required_grants, held)
        end)
        |> Enum.map(& &1.id)
    end
  end
end
