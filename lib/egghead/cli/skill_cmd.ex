defmodule Egghead.CLI.SkillCmd do
  @moduledoc """
  Skill listing/inspection commands.

  Skills are records with `class: skill`. They come from three sources:
  SKILLS_DIR drop-ins (auto-indexed), explicit class:skill records,
  and skills/*/SKILL.md records in the store. This command queries the
  unified index and surfaces validation status against the Agent Skills
  spec (https://agentskills.io/specification).
  """

  alias Egghead.CLI.Widgets
  alias Egghead.Skill

  def run(args) do
    if "--help" in args or "-h" in args do
      print_help()
    else
      {_opts, rest, _} = OptionParser.parse(args, switches: [], aliases: [])

      case rest do
        [] -> do_list()
        ["list" | _] -> do_list()
        ["show", name | _] -> do_show(name)
        ["inspect", name | _] -> do_show(name)
        ["show" | _] -> IO.puts("Usage: egghead skill show <name>")
        _ -> IO.puts("Usage: egghead skill <command>\nCommands: list, show <name>")
      end
    end
  end

  defp print_help do
    IO.puts("""
    USAGE
      egghead skill <command> [flags]

    DESCRIPTION
      List and inspect skills available to Egghead agents. Skills are
      records with class: skill, sourced from three places:
        - SKILLS_DIR  (default ~/.agents/skills, auto-indexed)
        - Records with class: skill in the store
        - Records at skills/<name>/SKILL.md in the store (auto-classified)

      See https://agentskills.io/specification for the SKILL.md format.

    COMMANDS
      list              List available skills (default)
      show <name>       Show a skill's body and validation status

    SEE ALSO
      egghead agent, design/capability-model
    """)
  end

  defp do_list do
    Egghead.CLI.start_app(:silent, web: false)

    # Hydrate each record so we can validate against the body. A handful
    # of skills on disk, one file read apiece — the cost is fine here.
    records =
      Egghead.search_by_class(:skill)
      |> Enum.map(fn r ->
        case Egghead.get_record(r.id) do
          {:ok, full} -> full
          _ -> r
        end
      end)
      |> Enum.sort_by(& &1.id)

    if records == [] do
      IO.puts("No skills found.")
      IO.puts("")
      IO.puts("  Skills live in these places:")
      IO.puts("    - ~/.agents/skills/<name>/SKILL.md (auto-indexed)")
      IO.puts("    - records with class: skill")
      IO.puts("    - records at skills/<name>/SKILL.md (auto-classified)")
    else
      Widgets.header("Skills")

      rows = Enum.map(records, &format_row/1)
      name_w = rows |> Enum.map(&String.length(&1.name)) |> Enum.max(fn -> 0 end) |> max(4)
      loc_w = rows |> Enum.map(&String.length(&1.location)) |> Enum.max(fn -> 0 end) |> max(8)

      IO.puts(
        "  #{Widgets.pad("NAME", name_w)}  #{Widgets.pad("LOCATION", loc_w)}  #{Widgets.pad("", 3)} DESCRIPTION"
      )

      IO.puts(
        "  #{String.duplicate("─", name_w)}  #{String.duplicate("─", loc_w)}  #{String.duplicate("─", 3)} #{String.duplicate("─", 40)}"
      )

      Enum.each(rows, fn row ->
        IO.puts(
          "  #{Widgets.pad(row.name, name_w)}  #{Widgets.pad(row.location, loc_w)}  #{row.status_marker}  #{truncate(row.desc, 40)}"
        )
      end)

      IO.puts("")
      IO.puts("  #{length(records)} skills")

      invalid_count = Enum.count(rows, &(&1.status_marker == "⚠"))

      if invalid_count > 0 do
        IO.puts(
          "  #{invalid_count} with validation issues — run `egghead skill show <name>` for details"
        )
      end
    end
  end

  defp do_show(name) do
    Egghead.CLI.start_app(:silent, web: false)

    case find_by_name(name) do
      nil ->
        IO.puts("Skill not found: #{name}")
        System.halt(1)

      lightweight ->
        # search_by_class returns lightweight records without body;
        # hydrate the full record before showing/validating.
        record =
          case Egghead.get_record(lightweight.id) do
            {:ok, full} -> full
            _ -> lightweight
          end

        Widgets.header("Skill: #{Skill.derive_name(record)}")
        IO.puts("  id:       #{record.id}")
        if record.source_path, do: IO.puts("  path:     #{shorten_path(record.source_path)}")

        if record.meta["description"],
          do: IO.puts("  description: #{record.meta["description"]}")

        if record.meta["compatibility"],
          do: IO.puts("  compatibility: #{record.meta["compatibility"]}")

        if record.meta["allowed-tools"],
          do: IO.puts("  allowed-tools: #{record.meta["allowed-tools"]}")

        case Skill.validate(record) do
          :ok ->
            IO.puts("  status:   \e[32m✓ conforms to Agent Skills spec\e[0m")

          {:error, issues} ->
            IO.puts("  status:   \e[33m⚠ validation issues\e[0m")
            Enum.each(issues, fn issue -> IO.puts("    - #{issue}") end)
        end

        IO.puts("")
        IO.puts(record.body || "")
    end
  end

  # --- helpers ---

  defp find_by_name(name) do
    records = Egghead.search_by_class(:skill)

    Enum.find(records, fn record ->
      Skill.derive_name(record) == name or record.id == name or
        record.id == "skills/#{name}" or record.id == "skills/#{name}/SKILL"
    end)
  end

  defp format_row(record) do
    status =
      case Skill.validate(record) do
        :ok -> "✓"
        {:error, _} -> "⚠"
      end

    %{
      name: Skill.derive_name(record),
      location: shorten_path(record.source_path),
      desc: record.meta["description"] || first_line(record.body),
      status_marker: status
    }
  end

  defp shorten_path(nil), do: "(virtual)"

  defp shorten_path(path) do
    home = System.user_home!() || ""

    if home != "" and String.starts_with?(path, home) do
      "~" <> String.replace_prefix(path, home, "")
    else
      path
    end
  end

  defp first_line(nil), do: ""

  defp first_line(body) do
    body
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
    |> String.replace(~r/^#+\s*/, "")
  end

  defp truncate(str, max) do
    if String.length(str) > max, do: String.slice(str, 0, max - 1) <> "…", else: str
  end
end
