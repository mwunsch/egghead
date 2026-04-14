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
        list              List running agents (default)
        new               Create a new agent interactively

      FLAGS
        --name <name>     Agent name (skip prompt, for `new`)
        --model <model>   Model string (skip picker, for `new`)
        --dry-run         Preview without saving (for `new`)
        --config PATH     Override config file location
        -h, --help        Show this help

      EXAMPLES
        $ egghead agent list
        $ egghead agent new
        $ egghead agent new --name scout
        $ egghead agent new --name scout --model anthropic/claude-haiku-4-5

      SEE ALSO
        egghead llm models, egghead config
      """)
    else
      {opts, rest, _} =
        OptionParser.parse(args,
          switches: [name: :string, model: :string, dry_run: :boolean],
          aliases: []
        )

      case rest do
        ["list" | _] -> do_list()
        ["new" | _] -> do_new(opts)
        [] -> do_list()
        _ -> IO.puts("Usage: egghead agent <command>\nCommands: list, new")
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
        defaults: ["search", "record_read"]
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
end
