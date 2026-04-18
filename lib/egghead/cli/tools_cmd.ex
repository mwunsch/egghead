defmodule Egghead.CLI.ToolsCmd do
  @moduledoc """
  `egghead tools` — catalog of tools available to agents, by source.

  Tools come from multiple sources:
  - **local** — built into Egghead (records, web_fetch, shell_exec, fs_*)
  - **mcp** — external MCP servers declared in config.yml

  This surface lets the user inspect what's available, which agents
  can use what, and register/remove MCP servers.
  """

  alias Egghead.CLI.Widgets
  alias Egghead.MCP.Client
  alias Egghead.MCP.Client.KnownServers

  def run(args) do
    cond do
      "--help" in args or "-h" in args ->
        print_help()

      true ->
        dispatch(args)
    end
  end

  defp dispatch([]), do: do_list(%{})

  defp dispatch(["list" | rest]), do: do_list(parse_list_opts(rest))
  defp dispatch(["mcp"]), do: do_mcp_list()
  defp dispatch(["mcp", "list"]), do: do_mcp_list()
  defp dispatch(["mcp", "available"]), do: do_mcp_available()
  defp dispatch(["mcp", "registry"]), do: do_mcp_available()
  defp dispatch(["mcp", "show", name | _]), do: do_mcp_show(name)
  defp dispatch(["mcp", "show"]), do: Widgets.error("usage: egghead tools mcp show <name>")
  defp dispatch(["mcp", "who", name | _]), do: do_mcp_who(name)
  defp dispatch(["mcp", "who"]), do: Widgets.error("usage: egghead tools mcp who <name>")
  defp dispatch(["mcp", "remove", name | _]), do: do_mcp_remove(name)
  defp dispatch(["mcp", "remove"]), do: Widgets.error("usage: egghead tools mcp remove <name>")
  defp dispatch(["mcp", "add" | rest]), do: do_mcp_add(rest)
  defp dispatch(_), do: print_help()

  defp parse_list_opts(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [agent: :string, source: :string],
        aliases: []
      )

    Map.new(opts)
  end

  # --- list ---

  defp do_list(opts) do
    # Don't wait for MCP here — we render immediately and let the MCP
    # rows animate in place as each server finishes its handshake.
    prepare_runtime(await_mcp: false)

    source = opts[:source] || "all"
    agent_id = opts[:agent]

    grants =
      case agent_id do
        nil -> nil
        id -> agent_grants(id)
      end

    if source in ["all", "local"] do
      Widgets.header("Local tools")
      print_local_tools(grants)
    end

    if source in ["all", "mcp"] do
      Widgets.header("MCP servers")
      render_mcp_reactive(grants, compact: true)
    end
  end

  defp print_local_tools(grants) do
    # Pull tool definitions without a filter; if grants given, mark
    # which ones would actually be offered. Strip MCP-prefixed names
    # — definitions_for merges local + MCP, but this section is
    # "Local tools" only. MCP tools appear under the MCP header.
    all =
      Egghead.Agent.Tools.definitions_for(all_local_grants())
      |> Enum.reject(&String.starts_with?(&1.name, "mcp__"))

    offered =
      case grants do
        nil ->
          MapSet.new(Enum.map(all, & &1.name))

        g ->
          Egghead.Agent.Tools.definitions_for(g)
          |> Enum.reject(&String.starts_with?(&1.name, "mcp__"))
          |> Enum.map(& &1.name)
          |> MapSet.new()
      end

    name_w =
      all |> Enum.map(&String.length(&1.name)) |> Enum.max(fn -> 0 end) |> max(16)

    Enum.each(all, fn tool ->
      available? = grants == nil or tool.name in offered
      line = "#{Widgets.pad(tool.name, name_w)}  — #{short_desc(tool.description)}"

      if available? do
        IO.puts("  \e[32m●\e[0m #{line}")
      else
        # Unavailable: red ○ marker + whole line in grey so this tool
        # recedes visually. Available tools stay in default color so
        # they're the prominent entries for this agent.
        IO.puts("  \e[31m○\e[0m \e[90m#{line}\e[0m")
      end
    end)
  end

  # --- mcp list (standalone, richer) ---

  defp do_mcp_list do
    prepare_runtime(await_mcp: false)

    servers = Application.get_env(:egghead, :mcp_servers, [])

    if servers == [] do
      IO.puts("No MCP servers configured.")
      IO.puts("  egghead tools mcp available   — see what's in the curated registry")
      IO.puts("  egghead tools mcp add <name>  — install a known server")
    else
      Widgets.header("MCP servers (#{length(servers)})")
      render_mcp_reactive(nil, compact: false)
    end
  end

  # Reactive MCP block renderer: prints one placeholder row per
  # server, then animates in place as each server reaches :ready
  # or :failed. Watchers run in parallel, so all servers make
  # progress concurrently; no server blocks another.
  defp render_mcp_reactive(grants, opts) do
    servers = Application.get_env(:egghead, :mcp_servers, [])
    compact? = Keyword.get(opts, :compact, false)

    if servers == [] do
      IO.puts("  (none configured — try: egghead tools mcp available)")
    else
      name_w =
        servers |> Enum.map(&String.length(&1.name)) |> Enum.max(fn -> 0 end) |> max(12)

      states = Map.new(servers, fn s -> {s.name, Client.Server.status(s.name)} end)
      draw_mcp_rows(servers, states, 0, name_w, grants, compact?)

      parent = self()

      _watchers =
        Enum.map(servers, fn s ->
          spawn_link(fn -> watch_until_terminal(s.name, parent) end)
        end)

      animate_mcp_loop(servers, states, 0, name_w, grants, compact?)
    end
  end

  # Per-server watcher: polls status 10x/sec, signals parent when a
  # terminal state is reached. Decoupled per server so a slow one
  # doesn't block a fast one.
  defp watch_until_terminal(name, parent) do
    case Client.Server.status(name) do
      state when state in [:ready, :failed] ->
        send(parent, {:mcp_done, name, state})

      _ ->
        Process.sleep(100)
        watch_until_terminal(name, parent)
    end
  end

  # Main render loop: spin frame every 100ms, bump on each watcher
  # message, exit when every server is terminal.
  defp animate_mcp_loop(servers, states, frame, name_w, grants, compact?) do
    if all_terminal?(states) do
      :ok
    else
      receive do
        {:mcp_done, name, state} ->
          states = Map.put(states, name, state)
          redraw_mcp(servers, states, frame, name_w, grants, compact?)
          animate_mcp_loop(servers, states, frame, name_w, grants, compact?)
      after
        100 ->
          redraw_mcp(servers, states, frame + 1, name_w, grants, compact?)
          animate_mcp_loop(servers, states, frame + 1, name_w, grants, compact?)
      end
    end
  end

  defp all_terminal?(states) do
    Enum.all?(states, fn {_name, state} -> state in [:ready, :failed] end)
  end

  defp redraw_mcp(servers, states, frame, name_w, grants, compact?) do
    # Cursor up N lines, then re-render each.
    IO.write("\e[#{length(servers)}A")
    draw_mcp_rows(servers, states, frame, name_w, grants, compact?)
  end

  defp draw_mcp_rows(servers, states, frame, name_w, grants, compact?) do
    Enum.each(servers, fn server ->
      state = Map.get(states, server.name, :offline)
      IO.write("\e[2K" <> mcp_row(server, state, frame, name_w, grants, compact?) <> "\n")
    end)
  end

  @spinner_frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  defp mcp_row(server, state, frame, name_w, grants, compact?) do
    indicator = state_indicator(state, frame)
    name_padded = Widgets.pad(server.name, name_w)
    transport = Atom.to_string(server.transport)

    detail =
      case state do
        :ready ->
          tool_count = length(Client.tools_for(server.name))
          eligible = Client.eligible_agents(server.name)

          if compact? do
            marker =
              if grants != nil and not Egghead.Capability.subset?(server.requires, grants),
                do: " (not eligible)",
                else: ""

            "  #{name_padded}#{marker}  — #{transport}, #{tool_count} tools · #{length(eligible)} agents"
          else
            agents_str = if eligible == [], do: "", else: "  agents: #{Enum.join(eligible, ", ")}"
            "  #{name_padded}  #{tool_count} tools  #{transport}#{agents_str}"
          end

        :failed ->
          "  #{name_padded}  failed to start"

        _ ->
          "  #{name_padded}  \e[90mconnecting…\e[0m"
      end

    "  " <> indicator <> detail
  end

  defp state_indicator(:ready, _frame), do: "\e[32m●\e[0m"
  defp state_indicator(:failed, _frame), do: "\e[31m✗\e[0m"

  defp state_indicator(_pending, frame) do
    "\e[36m#{Enum.at(@spinner_frames, rem(frame, length(@spinner_frames)))}\e[0m"
  end

  # --- mcp available (what's in the curated registry) ---

  defp do_mcp_available do
    registry = KnownServers.all()

    if map_size(registry) == 0 do
      IO.puts("Curated registry is empty.")
    else
      Widgets.header("Available MCP servers (#{map_size(registry)})")
      IO.puts("Install with: egghead tools mcp add <name>\n")

      name_w =
        registry |> Map.keys() |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end) |> max(12)

      configured =
        Application.get_env(:egghead, :mcp_servers, [])
        |> Enum.map(& &1.name)
        |> MapSet.new()

      registry
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.each(fn {name, spec} ->
        desc = spec["description"] || ""
        transport = spec["transport"] || "stdio"
        env_reqs = spec["env_required"] || []
        installed = if MapSet.member?(configured, name), do: " \e[32m(installed)\e[0m", else: ""

        IO.puts("  #{Widgets.pad(name, name_w)}  — #{desc}#{installed}")

        if String.contains?(spec["command"] || "", "<path>") do
          IO.puts("  #{String.duplicate(" ", name_w)}    prompts for <path> at install")
        end

        if env_reqs != [] do
          IO.puts("  #{String.duplicate(" ", name_w)}    needs env: #{Enum.join(env_reqs, ", ")}")
        end

        _ = transport
      end)
    end
  end

  # --- mcp show ---

  defp do_mcp_show(name) do
    prepare_runtime()

    case Client.config_for(name) do
      nil ->
        Widgets.error("No MCP server named #{inspect(name)}.")

      server ->
        Widgets.header(server.name)
        IO.puts("  transport: #{server.transport}")
        if server.command, do: IO.puts("  command:   #{server.command}")
        if server.url, do: IO.puts("  url:       #{server.url}")

        if server.env != %{} do
          IO.puts("  env:")
          Enum.each(server.env, fn {k, v} -> IO.puts("    #{k}: #{v}") end)
        end

        IO.puts("\n  requires:")

        Enum.each(server.requires, fn grant ->
          IO.puts("    - #{Egghead.Capability.grant_to_spec(grant)}")
        end)

        status = Client.Server.status(name)
        IO.puts("\n  status: #{status}")

        tools = Client.tools_for(name)

        if tools != [] do
          IO.puts("\n  tools:")

          Enum.each(tools, fn t ->
            IO.puts("    - #{t["name"]} \e[90m— #{short_desc(t["description"] || "")}\e[0m")
          end)
        end

        eligible = Client.eligible_agents(name)

        if eligible != [] do
          IO.puts("\n  eligible agents:")
          Enum.each(eligible, fn id -> IO.puts("    - #{id}") end)
        end
    end
  end

  # --- mcp who ---

  defp do_mcp_who(name) do
    prepare_runtime(await_mcp: false)

    case Client.config_for(name) do
      nil ->
        Widgets.error("No MCP server named #{inspect(name)}.")

      _server ->
        eligible = Client.eligible_agents(name)
        Enum.each(eligible, &IO.puts/1)
    end
  end

  # --- mcp remove ---

  defp do_mcp_remove(name) do
    prepare_runtime(await_mcp: false)

    case Egghead.Config.load() do
      {:ok, config} ->
        case Enum.split_with(config.mcp_servers, &(&1.name == name)) do
          {[], _} ->
            Widgets.error("No MCP server named #{inspect(name)}.")

          {_removed, kept} ->
            updated = %{config | mcp_servers: kept}

            case Egghead.Config.save(updated) do
              :ok ->
                Application.put_env(:egghead, :mcp_servers, kept)
                stop_running(name)
                Widgets.success("Removed #{name} from config.")

              {:error, reason} ->
                Widgets.error("Failed to save config: #{inspect(reason)}")
            end
        end

      {:error, reason} ->
        Widgets.error("Failed to load config: #{inspect(reason)}")
    end
  end

  # --- mcp add ---

  defp do_mcp_add(args) do
    {opts, rest, _} =
      OptionParser.parse(args, switches: [stdio: :string, http: :string, yes: :boolean])

    case rest do
      [name | _] -> do_mcp_add(name, Map.new(opts))
      [] -> Widgets.error("usage: egghead tools mcp add <name> [--stdio <cmd> | --http <url>]")
    end
  end

  defp do_mcp_add(name, opts) do
    prepare_runtime(await_mcp: false)

    cond do
      opts[:stdio] ->
        finalize_add(
          name,
          %{
            name: name,
            transport: :stdio,
            command: opts[:stdio],
            url: nil,
            env: %{},
            headers: %{},
            requires: []
          },
          opts,
          wizard_caps: true
        )

      opts[:http] ->
        finalize_add(
          name,
          %{
            name: name,
            transport: :http,
            command: nil,
            url: opts[:http],
            env: %{},
            headers: %{},
            requires: []
          },
          opts,
          wizard_caps: true
        )

      true ->
        case KnownServers.lookup(name) do
          nil ->
            Widgets.error("""
            Unknown server #{inspect(name)} (not in curated registry).
            Specify an explicit transport:
              egghead tools mcp add #{name} --stdio "your-command ..."
              egghead tools mcp add #{name} --http  https://example.com/mcp

            Known: #{Enum.join(Map.keys(KnownServers.all()), ", ")}
            """)

          spec ->
            add_from_registry(name, spec, opts)
        end
    end
  end

  defp add_from_registry(name, spec, opts) do
    spec = maybe_prompt_template(spec)

    server = %{
      name: name,
      transport: parse_transport_string(spec["transport"]),
      command: spec["command"],
      url: spec["url"],
      env: spec["env"] || %{},
      headers: spec["headers"] || %{},
      requires: Egghead.Capability.parse(spec["requires"] || [])
    }

    env_reqs = spec["env_required"] || []

    Enum.each(env_reqs, fn var ->
      if System.get_env(var) in [nil, ""] do
        Widgets.warn("$#{var} is not set — the server will likely fail to start.")
      end
    end)

    finalize_add(name, server, opts, wizard_caps: false)
  end

  # If the known-spec has <path> placeholders, prompt for substitution.
  defp maybe_prompt_template(spec) do
    command = spec["command"] || ""

    if String.contains?(command, "<path>") do
      path = Widgets.input("Path for <path> placeholder", default: "")

      if path == "" do
        Widgets.error("A path is required for this server.")
        System.halt(1)
      else
        KnownServers.substitute(spec, %{"path" => Path.expand(path)})
      end
    else
      spec
    end
  end

  # Shared finalize path: validate connection, (optionally) wizard
  # capabilities, confirm, write config.
  defp finalize_add(name, server, opts, wizard_caps: wizard?) do
    existing = Application.get_env(:egghead, :mcp_servers, [])

    if Enum.any?(existing, &(&1.name == name)) and not opts[:yes] do
      Widgets.error("MCP server #{inspect(name)} already exists. Remove it first.")
    else
      IO.puts("Starting #{name} for validation...")

      case Egghead.MCP.Client.Supervisor.start_server(server) do
        {:ok, _pid} ->
          wait_for_ready(name, 15_000)

          status = Client.Server.status(name)

          if status != :ready do
            Widgets.error("Server didn't initialize (status: #{status}).")
            stop_running(name)
          else
            tools = Client.tools_for(name)

            Widgets.success("Initialized. #{length(tools)} tool(s) discovered:")
            Enum.each(tools, fn t -> IO.puts("  - #{t["name"]}") end)

            server = if wizard?, do: wizard_capabilities(server), else: server

            unless opts[:yes] do
              if not Widgets.confirm("Write to config.yml?", default: true) do
                stop_running(name)
                Widgets.warn("Aborted. Server stopped.")
                System.halt(0)
              end
            end

            case write_config(server) do
              :ok ->
                Application.put_env(
                  :egghead,
                  :mcp_servers,
                  existing ++ [server]
                )

                Widgets.success("Added #{name} to config.")

              {:error, reason} ->
                stop_running(name)
                Widgets.error("Failed to save config: #{inspect(reason)}")
            end
          end

        {:error, reason} ->
          Widgets.error("Could not start server: #{inspect(reason)}")
      end
    end
  end

  defp wizard_capabilities(server) do
    resource_options = [
      {"net.get", "Fetches from the web"},
      {"net.post", "Writes/posts to the web"},
      {"fs.read", "Reads local files"},
      {"fs.write", "Writes local files"},
      {"shell.exec", "Runs shell commands"}
    ]

    items =
      Enum.map(resource_options, fn {key, desc} ->
        {"#{Widgets.pad(key, 12)} \e[90m— #{desc}\e[0m", key}
      end)

    picked =
      Widgets.multiselect(items,
        label: "What capabilities does this server need? (space to toggle, enter to confirm)"
      )

    requires =
      Enum.map(picked, fn key ->
        [resource, verb] = String.split(key, ".")
        scope = prompt_scope(resource, key)

        %Egghead.Capability.Grant{
          resource: String.to_atom(resource),
          verb: String.to_atom(verb),
          scope: scope
        }
      end)

    %{server | requires: requires}
  end

  defp prompt_scope("net", cap_key) do
    hosts =
      Widgets.input("  #{cap_key} hosts (comma-separated globs, or * for any)", default: "*")

    %{hosts: parse_list(hosts)}
  end

  defp prompt_scope("fs", cap_key) do
    paths = Widgets.input("  #{cap_key} paths (comma-separated globs)", default: "")
    %{paths: parse_list(paths)}
  end

  defp prompt_scope("shell", cap_key) do
    cmds = Widgets.input("  #{cap_key} commands (comma-separated)", default: "")
    %{cmds: parse_list(cmds)}
  end

  defp prompt_scope(_, _), do: %{}

  defp parse_list(""), do: []

  defp parse_list(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp write_config(server) do
    case Egghead.Config.load() do
      {:ok, config} ->
        updated = %{config | mcp_servers: config.mcp_servers ++ [server]}
        Egghead.Config.save(updated)

      {:error, :not_found} ->
        config = %Egghead.Config{mcp_servers: [server]}
        Egghead.Config.save(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stop_running(name) do
    case Egghead.Node.server_node() do
      nil ->
        case Registry.lookup(Egghead.MCP.Client.Registry, name) do
          [{pid, _}] -> DynamicSupervisor.terminate_child(Egghead.MCP.Client.Supervisor, pid)
          [] -> :ok
        end

      node ->
        :rpc.call(node, __MODULE__, :stop_running_local, [name])
    end
  end

  @doc false
  def stop_running_local(name) do
    case Registry.lookup(Egghead.MCP.Client.Registry, name) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Egghead.MCP.Client.Supervisor, pid)
      [] -> :ok
    end
  end

  defp wait_for_ready(name, deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    Stream.repeatedly(fn -> :ok end)
    |> Enum.reduce_while(nil, fn _, _ ->
      status = Client.Server.status(name)

      cond do
        status == :ready ->
          {:halt, :ok}

        status == :failed ->
          {:halt, :failed}

        System.monotonic_time(:millisecond) > deadline ->
          {:halt, :timeout}

        true ->
          Process.sleep(100)
          {:cont, nil}
      end
    end)
  end

  defp parse_transport_string("stdio"), do: :stdio
  defp parse_transport_string("http"), do: :http
  defp parse_transport_string(_), do: :stdio

  # Synthetic grants that cause all_tools to be returned regardless of agent.
  defp all_local_grants do
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

  defp agent_grants(id) do
    case Egghead.get_record(id) do
      {:ok, %{class: :agent, meta: meta}} ->
        Egghead.Capability.parse(meta["capabilities"] || [])

      _ ->
        Widgets.warn("Agent not found: #{id} (showing unfiltered catalog)")
        nil
    end
  end

  defp prepare_runtime(opts \\ []) do
    Egghead.CLI.prepare_runtime(await_mcp: Keyword.get(opts, :await_mcp, true))
  end

  defp short_desc(text) do
    text
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.slice(0, 72)
  end

  defp print_help do
    IO.puts("""
    USAGE
      egghead tools <subcommand> [flags]

    DESCRIPTION
      Inspect and manage tools available to agents. Tools come from
      several sources: built-in (local), MCP servers (remote), and —
      eventually — LLM-provider-hosted tools.

    SUBCOMMANDS
      list                              Catalog of all tools grouped by source
      mcp list                          List configured MCP servers
      mcp available                     Show the curated registry of known servers
      mcp show <name>                   Per-server detail (config, tools, agents)
      mcp add <name> [flags]            Register an MCP server
      mcp remove <name>                 Remove an MCP server from config
      mcp who <name>                    Print eligible agent ids (one per line)

    FLAGS (list)
      --agent <id>         Filter to tools the agent can actually use
      --source <kind>      one of: local, mcp, all (default)

    FLAGS (mcp add)
      --stdio <cmd>        Explicit stdio server command
      --http <url>         Explicit HTTP server URL
      --yes, -y            Skip confirmation prompts

    EXAMPLES
      $ egghead tools list
      $ egghead tools list --agent index --source mcp
      $ egghead tools mcp list
      $ egghead tools mcp add exa               # from curated registry
      $ egghead tools mcp add weather --stdio 'mcp-weather'
      $ egghead tools mcp who parallel-search

    SEE ALSO
      egghead agents grant, egghead agents capabilities
    """)
  end
end
