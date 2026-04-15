defmodule Egghead.TUI.ToolCatalog do
  @moduledoc """
  Rendering helpers for the `/tools` and `/mcp` TUI commands.

  Two surfaces consume this:

  - **Records mode** — `Model.show_tools/1` / `show_mcp/1` build a
    synthetic `%Record{class: :synthetic}` whose body is the
    markdown produced here. Wikilinks to `[[agents/*]]` let the
    user drill into eligible agents via the existing preview
    pipeline.
  - **Chat mode** — `apply_command(:cmd_tools, ...)` appends a
    compact `Entry.system/1` summary.

  The data is a snapshot at render time. If an MCP server is still
  handshaking, it shows as such; re-run the command to refresh.
  """

  alias Egghead.Agent.Tools
  alias Egghead.MCP.Client

  # --- Records mode (full markdown) ---

  @doc "Full tools catalog — local + MCP — rendered for the synthetic preview record."
  def tools_markdown do
    """
    # Tools

    #{local_section()}

    #{mcp_section()}
    """
  end

  @doc "MCP-only catalog for records mode."
  def mcp_markdown do
    """
    # MCP servers

    #{mcp_section()}
    """
  end

  # --- Chat mode (single-line system entry) ---

  @doc "Compact tools summary for the chat transcript."
  def tools_summary do
    local_count = length(local_tools())

    mcp_summary_line()
    |> then(fn mcp_line -> "Local: #{local_count} tools. #{mcp_line}" end)
  end

  @doc "MCP-only summary for the chat transcript."
  def mcp_summary do
    mcp_summary_line()
  end

  # --- Internal: local section ---

  defp local_section do
    defs = local_tools()

    if defs == [] do
      "## Local tools\n\n(no tools offered)"
    else
      rows =
        Enum.map_join(defs, "\n", fn t ->
          "- `#{t.name}` — #{short(t.description)}"
        end)

      "## Local tools (#{length(defs)})\n\n" <> rows
    end
  end

  defp local_tools do
    # definitions_for merges local + MCP offerings. For the "Local
    # tools" section we want only the local ones — strip any tool
    # whose name uses the mcp__ prefix.
    Tools.definitions_for(all_local_grants_for_display())
    |> Enum.reject(&String.starts_with?(&1.name, "mcp__"))
  end

  # Synthetic grants covering every local verb. The display is an
  # inventory of every LOCAL capability-gated tool the system knows
  # about, not filtered by any specific agent. (Narrowing by agent
  # can be a later enhancement.)
  defp all_local_grants_for_display do
    [
      %Egghead.Capability.Grant{resource: :records, verb: :read},
      %Egghead.Capability.Grant{resource: :records, verb: :create, scope: %{}},
      %Egghead.Capability.Grant{resource: :records, verb: :update, scope: %{}},
      %Egghead.Capability.Grant{resource: :agent, verb: :create},
      %Egghead.Capability.Grant{resource: :agent, verb: :grant},
      %Egghead.Capability.Grant{resource: :net, verb: :get, scope: %{hosts: ["*"]}},
      %Egghead.Capability.Grant{resource: :net, verb: :post, scope: %{hosts: ["*"]}},
      %Egghead.Capability.Grant{resource: :fs, verb: :read, scope: %{paths: ["*"]}},
      %Egghead.Capability.Grant{resource: :fs, verb: :write, scope: %{paths: ["*"]}},
      %Egghead.Capability.Grant{resource: :shell, verb: :exec, scope: %{cmds: ["*"]}}
    ]
  end

  # --- Internal: MCP section ---

  defp mcp_section do
    servers = Application.get_env(:egghead, :mcp_servers, [])

    if servers == [] do
      "## MCP servers\n\n(none configured — run `egghead tools mcp available` to see the curated registry)"
    else
      header = "## MCP servers (#{length(servers)})"
      body = Enum.map_join(servers, "\n\n", &mcp_server_block/1)
      header <> "\n\n" <> body
    end
  end

  defp mcp_server_block(server) do
    status = server_status(server.name)
    tools = Client.tools_for(server.name)
    eligible = Client.eligible_agents(server.name)

    tool_lines =
      case tools do
        [] ->
          "_no tools cached yet_"

        _ ->
          Enum.map_join(tools, "\n", fn t ->
            "- `#{t["name"]}` — #{short(t["description"] || "")}"
          end)
      end

    agents_line =
      case eligible do
        [] ->
          "_no agents currently eligible_"

        _ ->
          "Eligible agents: " <>
            Enum.map_join(eligible, ", ", fn id -> "[[#{id}]]" end)
      end

    """
    ### #{server.name}  _#{status}_ · #{server.transport}

    #{agents_line}

    #{tool_lines}\
    """
  end

  defp mcp_summary_line do
    servers = Application.get_env(:egghead, :mcp_servers, [])

    case servers do
      [] ->
        "MCP: none configured (see `egghead tools mcp available`)."

      _ ->
        total_tools =
          Enum.reduce(servers, 0, fn s, acc -> acc + length(Client.tools_for(s.name)) end)

        status_parts =
          Enum.map_join(servers, ", ", fn s ->
            status = server_status(s.name)
            "#{s.name} (#{status})"
          end)

        "MCP: #{length(servers)} servers, #{total_tools} tools — #{status_parts}"
    end
  end

  defp server_status(name) do
    case Client.Server.status(name) do
      :ready -> "ready"
      :initializing -> "initializing…"
      :failed -> "failed"
      _ -> "offline"
    end
  end

  defp short(text) when is_binary(text) do
    text
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.slice(0, 100)
    |> balance_backticks()
  end

  defp short(_), do: ""

  # Truncation can slice mid-code-span (`foo{bar → unclosed backtick),
  # which breaks Earmark's parse for the whole doc. Count backticks
  # and close the dangling one so the description stays parseable.
  defp balance_backticks(text) do
    ticks = text |> String.graphemes() |> Enum.count(&(&1 == "`"))
    if rem(ticks, 2) == 1, do: text <> "`", else: text
  end
end
