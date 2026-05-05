defmodule Egghead.CLI.AgentCmd do
  @moduledoc false

  alias Egghead.CLI.Widgets
  alias Egghead.Agent.Wizard

  def run(args) do
    if "--help" in args or "-h" in args do
      IO.puts("""
      USAGE
        egghead agents <command> [flags]

      DESCRIPTION
        Manage Egghead agents. Agents are markdown records with class: agent
        whose body serves as their system prompt.

      COMMANDS
        list                              List running agents (default)
        new                               Create a new agent interactively
        grant <agent-id> [cap]            Add a capability to an agent.
                                          Omit <cap> for an interactive picker.
        revoke <agent-id> <cap>           Remove a capability from an agent
        capabilities <agent-id>           Show an agent's held capabilities

      FLAGS
        --name <name>     Agent name (skip prompt, for `new`)
        --model <model>   Model string (skip picker, for `new`)
        --dry-run         Preview without saving (for `new`)
        --yes, -y         Skip confirmation prompt (for `grant`)
        --config PATH     Override config file location
        -h, --help        Show this help

      EXAMPLES
        $ egghead agents list
        $ egghead agents new
        $ egghead agents grant index 'net.get{hosts=[*.github.com]}'
        $ egghead agents revoke index records.update
        $ egghead agents capabilities index

      SEE ALSO
        egghead llm models, egghead skills check
      """)
    else
      {opts, rest, _} =
        OptionParser.parse(args,
          switches: [name: :string, model: :string, dry_run: :boolean, yes: :boolean],
          aliases: [y: :yes]
        )

      case rest do
        ["list" | _] ->
          do_list()

        ["new" | _] ->
          do_new(opts)

        ["grant", agent_id, cap | _] ->
          do_grant(agent_id, cap, opts)

        ["grant", agent_id] ->
          do_grant_interactive(agent_id, opts)

        ["revoke", agent_id, cap | _] ->
          do_revoke(agent_id, cap)

        ["capabilities", agent_id | _] ->
          do_capabilities(agent_id)

        ["caps", agent_id | _] ->
          do_capabilities(agent_id)

        [] ->
          do_list()

        _ ->
          IO.puts(
            "Usage: egghead agents <command>\nCommands: list, new, grant, revoke, capabilities"
          )
      end
    end
  end

  defp do_list do
    Egghead.CLI.prepare_runtime()

    agents = Egghead.list_agents()

    if agents == [] do
      IO.puts("No agents running.")
    else
      Widgets.header("Agents")

      name_w = agents |> Enum.map(&String.length(&1.name)) |> Enum.max(fn -> 0 end) |> max(4)
      id_w = agents |> Enum.map(&String.length(&1.id)) |> Enum.max(fn -> 0 end) |> max(2)

      IO.puts("  #{Widgets.pad("NAME", name_w)}  #{Widgets.pad("ID", id_w)}  MODEL")

      IO.puts(
        "  #{String.duplicate("─", name_w)}  #{String.duplicate("─", id_w)}  #{String.duplicate("─", 30)}"
      )

      Enum.each(agents, fn agent ->
        IO.puts(
          "  #{Widgets.pad(agent.name, name_w)}  #{Widgets.pad(agent.id, id_w)}  #{agent.model}"
        )
      end)

      IO.puts("")
      IO.puts("  #{length(agents)} agents")
    end
  end

  defp do_new(opts) do
    dry_run = opts[:dry_run] || false

    IO.puts("")
    Widgets.puts("\e[1mCreate a New Agent\e[0m")
    IO.puts("")

    name = opts[:name] || Widgets.input("Agent name")

    Egghead.CLI.prepare_runtime()

    model = opts[:model] || discover_then_pick_model()

    tags_input = Widgets.input("Tags (comma-separated)", default: "")

    tags =
      (tags_input || "")
      |> String.split(~r/[,\s]+/, trim: true)
      |> Enum.map(&String.trim/1)

    capabilities =
      Widgets.multiselect(
        Wizard.capability_labels(),
        label: "Capabilities:",
        defaults: ["records.read"]
      )

    sandbox = prompt_for_sandbox(capabilities)

    instructions = edit_instructions(name)

    params =
      %{
        name: name,
        model: model,
        tags: tags,
        capabilities: capabilities,
        instructions: instructions
      }
      |> maybe_put_param(:sandbox, sandbox)

    if dry_run do
      Widgets.header("Dry run — would create agents/#{name}:")
      IO.puts("")
      IO.puts("---")
      IO.puts("class: agent")
      IO.puts("model: #{model}")
      IO.puts("tags: [#{Enum.join(["agent" | tags], ", ")}]")
      if sandbox, do: IO.puts("sandbox: #{sandbox}")
      IO.puts("capabilities: [#{Enum.join(capabilities, ", ")}]")
      IO.puts("---")
      IO.puts("")
      IO.puts(instructions)
    else
      case Wizard.create(params) do
        {:ok, record} ->
          IO.puts("")
          Widgets.success("Created agent: #{record.id}")
          if record.source_path, do: IO.puts("  #{record.source_path}")

        {:error, errors} when is_map(errors) ->
          IO.puts("")

          Enum.each(errors, fn {field, messages} ->
            Enum.each(messages, fn msg -> Widgets.error("#{field}: #{msg}") end)
          end)

        {:error, reason} ->
          Widgets.error("Failed: #{inspect(reason)}")
      end
    end
  end

  # Spinner must wrap ONLY the discovery — `pick_model` is interactive
  # (arrow keys, type-to-filter, redraws) and a still-running spinner
  # would race the picker's ANSI output, looping the model list and
  # leaving its label glued to the screen.
  defp discover_then_pick_model do
    Widgets.spinner("Discovering models...", fn ->
      Egghead.LLM.Registry.await_discovery()
    end)

    pick_model()
  end

  defp pick_model do
    models = Egghead.LLM.Registry.list_models()

    if models != [] do
      groups =
        models
        |> Enum.group_by(& &1.provider)
        |> Enum.sort_by(fn {p, _} -> p end)

      selected =
        Widgets.select_grouped(groups,
          label: "Model:",
          render_as: fn model ->
            ctx = Widgets.format_context(model[:context_window])
            "#{Widgets.pad(model.id, 28)} #{Widgets.dim(ctx)}"
          end
        )

      if selected, do: selected.full_id, else: "anthropic/claude-sonnet-4-6"
    else
      Widgets.input("Model", default: "anthropic/claude-sonnet-4-6")
    end
  end

  # Contextual sandbox prompt. Only asks if the user picked at least one
  # external capability (fs.*, proc.*, net.*) — a records-only agent has
  # nothing to fence. Offers the global config `sandbox:` as the default
  # when set, so most users can hit Enter and inherit it.
  defp prompt_for_sandbox(capabilities) do
    if needs_sandbox?(capabilities) do
      IO.puts("")
      Widgets.puts("  \e[2mSandbox root — the agent's fence for fs.* and proc.*\e[0m")
      Widgets.puts("  \e[2mThe agent can only read/write/exec under this path.\e[0m")
      Widgets.puts("  \e[2mLeave blank to use the global sandbox from config.yml.\e[0m")

      default = Path.expand(global_sandbox() || System.user_home!())

      case Widgets.input("Sandbox root", default: default) do
        nil -> nil
        "" -> nil
        path -> String.trim(path)
      end
    else
      nil
    end
  end

  defp needs_sandbox?(capabilities) do
    Enum.any?(capabilities, fn cap ->
      String.starts_with?(cap, "fs.") or
        String.starts_with?(cap, "proc.") or
        String.starts_with?(cap, "net.")
    end)
  end

  defp global_sandbox do
    case Egghead.Config.load() do
      {:ok, cfg} -> Egghead.Config.sandbox(cfg)
      _ -> nil
    end
  end

  defp maybe_put_param(params, _key, nil), do: params
  defp maybe_put_param(params, _key, ""), do: params
  defp maybe_put_param(params, key, value), do: Map.put(params, key, value)

  defp edit_instructions(name) do
    editor = System.get_env("EDITOR") || System.get_env("VISUAL") || "vi"
    template = Wizard.template(name)

    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "egghead-agent-#{name}-#{:erlang.unique_integer([:positive])}.md"
      )

    File.write!(tmp_path, template)

    IO.puts("")
    Widgets.puts("Opening \e[36m#{editor}\e[0m to write agent instructions...")
    IO.puts("Save and close to continue.")
    IO.puts("")

    exit_code = spawn_editor(editor, tmp_path)

    if exit_code == 0 do
      content = File.read!(tmp_path)
      File.rm(tmp_path)
      content
    else
      File.rm(tmp_path)
      IO.puts("Editor exited with code #{exit_code}, using template.")
      template
    end
  end

  # Hand `$EDITOR` the BEAM's controlling tty directly via a shell
  # port with `:nouse_stdio`. The previous `System.cmd(..., into:
  # IO.stream(...))` piped the editor's I/O through the BEAM, which
  # left vim without a real tty — buffered bytes from earlier raw-mode
  # widgets (terminal device-status replies, residual keystrokes) then
  # leaked in as keystrokes, dropping the user into insert mode with
  # garbage prepended and an unresponsive Esc. Mirrors
  # `Egghead.TUI.Records.Update.spawn_editor/1`.
  defp spawn_editor(editor, path) do
    sh = System.find_executable("sh") || "/bin/sh"

    # Drain any pending bytes (terminal responses to the picker's
    # ANSI queries, stray keystrokes) before handing the tty over.
    safe_drain_input()

    escaped = String.replace(path, "'", "'\\''")

    port =
      Port.open({:spawn_executable, sh}, [
        :nouse_stdio,
        :exit_status,
        args: ["-c", "#{editor} '#{escaped}'"]
      ])

    receive do
      {^port, {:exit_status, status}} -> status
    end
  end

  defp safe_drain_input do
    if Code.ensure_loaded?(Egghead.OpenTUI.Bridge) and
         function_exported?(Egghead.OpenTUI.Bridge, :drain_input, 1) do
      try do
        Egghead.OpenTUI.Bridge.drain_input(50)
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # --- Capability management ---

  defp do_grant(agent_id, cap_spec, opts) do
    Egghead.CLI.prepare_runtime()

    case Egghead.Capability.parse_grant_spec(cap_spec) do
      {:ok, parsed} ->
        grants = Egghead.Capability.parse([parsed])

        if grants == [] do
          Widgets.error("Could not interpret capability: #{cap_spec}")
          System.halt(1)
        end

        case Egghead.get_record(agent_id) do
          {:ok, record} ->
            if record.class != :agent do
              Widgets.error("#{agent_id} is not an agent record (class: #{record.class})")
              System.halt(1)
            end

            new_cap = hd(grants)
            {existing, dissolve_attrs} = dissolve_access(record)

            if opts[:yes] || confirm_grant(agent_id, new_cap) do
              merged = existing ++ [parsed]
              attrs = Map.merge(%{"capabilities" => merged}, dissolve_attrs)

              case Egghead.update_record(agent_id, attrs) do
                {:ok, _} ->
                  Widgets.success(
                    "Granted #{Egghead.Capability.grant_to_spec(new_cap)} to #{agent_id}"
                  )

                  IO.puts("  Agent will hot-reload with new capability.")

                {:error, reason} ->
                  Widgets.error("Update failed: #{inspect(reason)}")
                  System.halt(1)
              end
            else
              IO.puts("  Cancelled.")
            end

          {:error, :not_found} ->
            Widgets.error("Agent not found: #{agent_id}")
            System.halt(1)
        end

      {:error, reason} ->
        Widgets.error("Invalid capability spec: #{reason}")
        System.halt(1)
    end
  end

  # Interactive grant: pick a capability from the Catalog by short
  # description, then prompt for scope values if the resource
  # supports them.
  defp do_grant_interactive(agent_id, opts) do
    Egghead.CLI.prepare_runtime()

    case Egghead.get_record(agent_id) do
      {:ok, record} when record.class == :agent ->
        groups = build_capability_groups()

        case Widgets.select_grouped(groups,
               label: "Capability:",
               render_as: &render_catalog_entry/1
             ) do
          nil ->
            IO.puts("  Cancelled.")

          %{resource: r, verb: v} = entry ->
            spec = prompt_for_scope(r, v, entry)

            if spec do
              do_grant(agent_id, spec, opts)
            else
              IO.puts("  Cancelled.")
            end
        end

      {:ok, _} ->
        Widgets.error("#{agent_id} is not an agent record")
        System.halt(1)

      {:error, :not_found} ->
        Widgets.error("Agent not found: #{agent_id}")
        System.halt(1)
    end
  end

  defp build_capability_groups do
    risk_order = %{low: 0, medium: 1, high: 2}

    Egghead.Capability.Catalog.all()
    |> Enum.map(fn {r, v, meta} ->
      %{resource: r, verb: v, short: meta.short, risk: meta.risk}
    end)
    |> Enum.group_by(& &1.resource)
    |> Enum.map(fn {resource, entries} ->
      sorted =
        Enum.sort_by(entries, fn e ->
          {Map.get(risk_order, e.risk, 1), "#{e.verb}"}
        end)

      {to_string(resource), sorted}
    end)
    |> Enum.sort_by(fn {resource, _} -> resource end)
  end

  defp render_catalog_entry(%{verb: v, short: short, risk: risk}) do
    marker = risk_marker(risk)
    "#{marker} #{Widgets.pad("#{v}", 10)} #{Widgets.dim(short)}"
  end

  # If the resource supports scoping, prompt the user for values.
  # External resources (net, fs, shell) default to empty → bare
  # grants are inert, so we require at least one scope entry.
  defp prompt_for_scope(:net, verb, _entry) do
    hosts = Widgets.input("Hosts (comma-separated, `*` for any)", default: "*")

    if hosts == nil or String.trim(hosts) == "" do
      nil
    else
      list = hosts |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      "net.#{verb}{hosts=[#{Enum.join(list, ",")}]}"
    end
  end

  defp prompt_for_scope(:fs, verb, _entry) do
    paths = Widgets.input("Paths (comma-separated globs)")

    if paths == nil or String.trim(paths) == "" do
      nil
    else
      list = paths |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      "fs.#{verb}{paths=[#{Enum.join(list, ",")}]}"
    end
  end

  defp prompt_for_scope(:proc, :exec, _entry) do
    cmds = Widgets.input("Commands (comma-separated argv[0])", default: "")
    patterns = Widgets.input("Patterns (e.g. `git:*`, `npm test`)", default: "")

    scope_parts =
      []
      |> then(fn acc ->
        if cmds != nil and String.trim(cmds) != "" do
          list = cmds |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
          ["cmds=[#{Enum.join(list, ",")}]" | acc]
        else
          acc
        end
      end)
      |> then(fn acc ->
        if patterns != nil and String.trim(patterns) != "" do
          list = patterns |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
          ["patterns=[#{Enum.join(list, ",")}]" | acc]
        else
          acc
        end
      end)

    if scope_parts == [] do
      nil
    else
      "proc.exec{#{Enum.join(scope_parts, ",")}}"
    end
  end

  defp prompt_for_scope(:records, verb, _entry)
       when verb in [:create, :update, :delete] do
    classes = Widgets.input("Classes (optional, comma-separated)", default: "")

    if classes == nil or String.trim(classes) == "" do
      "records.#{verb}"
    else
      list = classes |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      "records.#{verb}{classes=[#{Enum.join(list, ",")}]}"
    end
  end

  # Bare verbs (records.read, agent.*) — no scope needed.
  defp prompt_for_scope(resource, verb, _entry) do
    "#{resource}.#{verb}"
  end

  defp do_revoke(agent_id, cap_spec) do
    Egghead.CLI.prepare_runtime()

    case Egghead.Capability.parse_grant_spec(cap_spec) do
      {:ok, parsed} ->
        grants = Egghead.Capability.parse([parsed])

        if grants == [] do
          Widgets.error("Could not interpret capability: #{cap_spec}")
          System.halt(1)
        end

        target = hd(grants)

        case Egghead.get_record(agent_id) do
          {:ok, record} ->
            {existing, dissolve_attrs} = dissolve_access(record)
            filtered = Enum.reject(existing, &same_grant?(&1, target))

            cond do
              filtered == existing ->
                IO.puts("No change — #{agent_id} doesn't hold #{cap_spec}.")

              true ->
                attrs = Map.merge(%{"capabilities" => filtered}, dissolve_attrs)

                case Egghead.update_record(agent_id, attrs) do
                  {:ok, _} ->
                    Widgets.success(
                      "Revoked #{Egghead.Capability.grant_to_spec(target)} from #{agent_id}"
                    )

                  {:error, reason} ->
                    Widgets.error("Update failed: #{inspect(reason)}")
                    System.halt(1)
                end
            end

          {:error, :not_found} ->
            Widgets.error("Agent not found: #{agent_id}")
            System.halt(1)
        end

      {:error, reason} ->
        Widgets.error("Invalid capability spec: #{reason}")
        System.halt(1)
    end
  end

  defp do_capabilities(agent_id) do
    Egghead.CLI.prepare_runtime()

    # Try the record store first, fall back to the running agent's state
    # (handles built-in agents like "index" that have no file on disk).
    # Route through the projection so `access:` expansion and the
    # default `records.read` both apply — mirrors what the live agent
    # GenServer holds.
    grants =
      case Egghead.get_record(agent_id) do
        {:ok, record} when record.class == :agent ->
          Egghead.Record.Agent.parse_capabilities(record)

        _ ->
          case Enum.find(Egghead.list_agents(), &(&1.id == agent_id)) do
            %{capabilities: caps} when is_list(caps) -> caps
            _ -> nil
          end
      end

    if is_nil(grants) do
      Widgets.error("Agent not found: #{agent_id}")
      System.halt(1)
    end

    grants = Egghead.Capability.Catalog.sort_by_risk(grants)

    Widgets.header("Capabilities: #{agent_id}")

    if grants == [] do
      IO.puts("  (none)")
    else
      Enum.each(grants, fn grant ->
        marker = risk_marker(Egghead.Capability.Catalog.risk(grant))
        Widgets.puts("  #{marker} #{Egghead.Capability.Catalog.describe(grant)}")
      end)

      IO.puts("")
      IO.puts("  #{length(grants)} capabilities")
    end
  end

  defp confirm_grant(agent_id, %Egghead.Capability.Grant{} = grant) do
    risk = Egghead.Capability.Catalog.risk(grant)
    risk_label = risk |> to_string() |> String.upcase()
    description = Egghead.Capability.Catalog.describe(grant)

    IO.puts("")
    IO.puts("  Agent:  #{agent_id}")
    IO.puts("  Grant:  #{Egghead.Capability.grant_to_spec(grant)}")
    IO.puts("  Risk:   #{risk_label}")
    IO.puts("  Effect: #{description}")
    IO.puts("")

    Widgets.confirm("Grant this capability?", default: false)
  end

  defp same_grant?(existing, %Egghead.Capability.Grant{resource: r, verb: v}) do
    case Egghead.Capability.parse([existing]) do
      [%Egghead.Capability.Grant{resource: ^r, verb: ^v}] -> true
      _ -> false
    end
  end

  # Fold top-level shortcuts (`access:`, `sandbox:`) into a unified
  # yaml-form capability list.
  #
  # Returns `{unified_caps, attrs_override}`. `attrs_override` carries
  # `%{"access" => :remove, "sandbox" => :remove}` entries for whichever
  # shortcuts were present, so the caller can include them in the
  # `update_record/2` attrs to delete the shortcuts in the same write
  # that modifies `capabilities:`. The contract: frontmatter on disk
  # always reflects the agent's real authority — no shortcut sitting
  # next to an out-of-sync explicit list.
  defp dissolve_access(record) do
    has_access? = Map.has_key?(record.meta, "access")
    has_sandbox? = Map.has_key?(record.meta, "sandbox")
    has_caps? = Map.has_key?(record.meta, "capabilities")

    cond do
      # Any shortcut present — dissolve to explicit capabilities. Route
      # through Record.Agent.parse_capabilities/1 so the projection
      # matches the live agent (access + sandbox + capabilities + default
      # all combine the same way in one place). Mark the shortcuts for
      # removal in the same write.
      has_access? or has_sandbox? ->
        unified = effective_caps_as_yaml(record)

        removes =
          %{}
          |> maybe_mark_removed(has_access?, "access")
          |> maybe_mark_removed(has_sandbox?, "sandbox")

        {unified, removes}

      # No shortcut but also no explicit capabilities — the agent relies
      # on the no-keys default (`records.read`). A grant here would
      # silently drop that default; materialize it before adding the new
      # grant so the agent's authority doesn't regress.
      not has_caps? ->
        {effective_caps_as_yaml(record), %{}}

      # Explicit capabilities key present — pass through as-is. The
      # existing list is the source of truth; we don't expand, we don't
      # inject defaults. Includes the explicit-opt-out case
      # (`capabilities: []`), which must be preserved.
      true ->
        {List.wrap(record.meta["capabilities"] || []), %{}}
    end
  end

  defp effective_caps_as_yaml(record) do
    record
    |> Egghead.Record.Agent.parse_capabilities()
    |> Enum.map(&Egghead.Capability.grant_to_yaml/1)
  end

  defp maybe_mark_removed(map, false, _key), do: map
  defp maybe_mark_removed(map, true, key), do: Map.put(map, key, :remove)

  defp risk_marker(:low), do: "\e[32m●\e[0m"
  defp risk_marker(:medium), do: "\e[33m●\e[0m"
  defp risk_marker(:high), do: "\e[31m●\e[0m"
  defp risk_marker(_), do: "○"
end
