defmodule Egghead.CLI.AgentCmd do
  @moduledoc "Agent management commands."

  alias Egghead.CLI.Widgets
  alias Egghead.Agent.Wizard

  def run(args) do
    if "--help" in args or "-h" in args do
      IO.puts("""
      USAGE
        egghead agent <command> [flags]

      DESCRIPTION
        Manage Egghead agents. Agents are markdown records with class: agent
        whose body serves as their system prompt.

      COMMANDS
        list                              List running agents (default)
        new                               Create a new agent interactively
        grant <agent-id> <cap>            Add a capability to an agent
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
        $ egghead agent list
        $ egghead agent new
        $ egghead agent grant agents/scout 'net.get{hosts=[*.github.com]}'
        $ egghead agent revoke agents/scout records.update
        $ egghead agent capabilities agents/scout

      SEE ALSO
        egghead llm models, egghead skill check, design/capability-model
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
            "Usage: egghead agent <command>\nCommands: list, new, grant, revoke, capabilities"
          )
      end
    end
  end

  defp do_list do
    Egghead.CLI.start_app(:silent, web: false)
    Egghead.Agent.Supervisor.sync_agents()

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
    IO.puts("\e[1mCreate a New Agent\e[0m")
    IO.puts("")

    name = opts[:name] || Widgets.input("Agent name")

    Egghead.CLI.start_app(:silent, web: false)

    model =
      opts[:model] ||
        Widgets.spinner("Discovering models...", fn ->
          Egghead.LLM.Registry.await_discovery()
          pick_model()
        end)

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

    instructions = edit_instructions(name)

    params = %{
      name: name,
      model: model,
      tags: tags,
      capabilities: capabilities,
      instructions: instructions
    }

    if dry_run do
      Widgets.header("Dry run — would create agents/#{name}:")
      IO.puts("")
      IO.puts("---")
      IO.puts("class: agent")
      IO.puts("model: #{model}")
      IO.puts("tags: [#{Enum.join(["agent" | tags], ", ")}]")
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
            "#{Widgets.pad(model.id, 28)} \e[90m#{ctx}\e[0m"
          end
        )

      if selected, do: selected.full_id, else: "anthropic/claude-sonnet-4-6"
    else
      Widgets.input("Model", default: "anthropic/claude-sonnet-4-6")
    end
  end

  defp edit_instructions(name) do
    editor = System.get_env("EDITOR") || "vi"
    template = Wizard.template(name)

    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "egghead-agent-#{name}-#{:erlang.unique_integer([:positive])}.md"
      )

    File.write!(tmp_path, template)

    IO.puts("")
    IO.puts("Opening \e[36m#{editor}\e[0m to write agent instructions...")
    IO.puts("Save and close to continue.")
    IO.puts("")

    {_, exit_code} = System.cmd(editor, [tmp_path], into: IO.stream(:stdio, :line))

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

  # --- Capability management ---

  defp do_grant(agent_id, cap_spec, opts) do
    Egghead.CLI.start_app(:silent, web: false)

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
            existing = record.meta["capabilities"] || []

            if opts[:yes] || confirm_grant(agent_id, new_cap) do
              merged = existing ++ [parsed]

              case Egghead.update_record(agent_id, %{"capabilities" => merged}) do
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

  defp do_revoke(agent_id, cap_spec) do
    Egghead.CLI.start_app(:silent, web: false)

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
            existing = record.meta["capabilities"] || []
            filtered = Enum.reject(existing, &same_grant?(&1, target))

            cond do
              filtered == existing ->
                IO.puts("No change — #{agent_id} doesn't hold #{cap_spec}.")

              true ->
                case Egghead.update_record(agent_id, %{"capabilities" => filtered}) do
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
    Egghead.CLI.start_app(:silent, web: false)

    case Egghead.get_record(agent_id) do
      {:ok, record} ->
        if record.class != :agent do
          Widgets.error("#{agent_id} is not an agent record (class: #{record.class})")
          System.halt(1)
        end

        raw = record.meta["capabilities"] || []
        grants = Egghead.Capability.parse(raw) |> Egghead.Capability.Catalog.sort_by_risk()

        Widgets.header("Capabilities: #{agent_id}")

        if grants == [] do
          IO.puts("  (none)")
        else
          Enum.each(grants, fn grant ->
            marker = risk_marker(Egghead.Capability.Catalog.risk(grant))
            IO.puts("  #{marker} #{Egghead.Capability.Catalog.describe(grant)}")
          end)

          IO.puts("")
          IO.puts("  #{length(grants)} capabilities")
        end

      {:error, :not_found} ->
        Widgets.error("Agent not found: #{agent_id}")
        System.halt(1)
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

  defp risk_marker(:low), do: "\e[32m●\e[0m"
  defp risk_marker(:medium), do: "\e[33m●\e[0m"
  defp risk_marker(:high), do: "\e[31m●\e[0m"
  defp risk_marker(_), do: "○"
end
