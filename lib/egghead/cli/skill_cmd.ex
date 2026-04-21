defmodule Egghead.CLI.SkillCmd do
  @moduledoc false

  alias Egghead.CLI.Widgets
  alias Egghead.Skill

  def run(args) do
    if "--help" in args or "-h" in args do
      print_help()
    else
      {opts, rest, _} =
        OptionParser.parse(args, switches: [agent: :string], aliases: [a: :agent])

      case rest do
        [] -> do_list()
        ["list" | _] -> do_list()
        ["show", name | _] -> do_show(name)
        ["inspect", name | _] -> do_show(name)
        ["check", name | _] -> do_check(name, opts)
        ["show" | _] -> IO.puts("Usage: egghead skills show <name>")
        ["check" | _] -> IO.puts("Usage: egghead skills check <name> --agent <id>")
        _ -> IO.puts("Usage: egghead skills <command>\nCommands: list, show, check <name>")
      end
    end
  end

  defp print_help do
    IO.puts("""
    USAGE
      egghead skills <command> [flags]

    DESCRIPTION
      List and inspect skills available to Egghead agents. Skills are
      records with class: skill, sourced from three places:
        - SKILLS_DIR  (default ~/.agents/skills, auto-indexed)
        - Records with class: skill in the store
        - Records at skills/<name>/SKILL.md in the store (auto-classified)

      See https://agentskills.io/specification for the SKILL.md format.

    COMMANDS
      list                              List available skills (default)
      show <name>                       Show a skill's body and validation status
      check <name> --agent <id>         Report the capability delta between a
                                        skill's allowed-tools and an agent's grants

    SEE ALSO
      egghead agents
    """)
  end

  defp do_list do
    Egghead.CLI.prepare_runtime()

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

      IO.puts("  #{Widgets.pad("NAME", name_w)}  #{Widgets.pad("LOCATION", loc_w)}  DESCRIPTION")

      IO.puts(
        "  #{String.duplicate("─", name_w)}  #{String.duplicate("─", loc_w)}  #{String.duplicate("─", 40)}"
      )

      Enum.each(rows, fn row ->
        IO.puts(
          "  #{row.status_marker} #{Widgets.pad(row.name, name_w)}  #{Widgets.pad(row.location, loc_w)}  #{truncate(row.desc, 40)}"
        )
      end)

      IO.puts("")
      IO.puts("  #{length(records)} skills")

      invalid_count = Enum.count(rows, &(&1.status_marker == "⚠"))

      if invalid_count > 0 do
        IO.puts(
          "  #{invalid_count} with validation issues — run `egghead skills show <name>` for details"
        )
      end
    end
  end

  defp do_check(name, opts) do
    Egghead.CLI.prepare_runtime()

    agent_id = opts[:agent]

    if is_nil(agent_id) do
      IO.puts("Usage: egghead skills check <name> --agent <agent_id>")
      System.halt(1)
    end

    case find_by_name(name) do
      nil ->
        IO.puts("Skill not found: #{name}")
        System.halt(1)

      lightweight ->
        record =
          case Egghead.get_record(lightweight.id) do
            {:ok, full} -> full
            _ -> lightweight
          end

        agent_record = resolve_agent(agent_id)

        if is_nil(agent_record) do
          IO.puts("Agent not found: #{agent_id}")
          System.halt(1)
        else
          report_delta(record, agent_record)
        end
    end
  end

  defp report_delta(skill_record, agent_record) do
    skill_name = Skill.derive_name(skill_record)
    agent_grants = Egghead.Capability.parse(agent_record.meta["capabilities"] || [])

    %{requests: requests, unknown: unknown} = Skill.derive_requirements(skill_record)

    Widgets.header("Capability check: #{skill_name} → #{agent_record.id}")

    if requests == [] and unknown == [] do
      IO.puts("  Skill declares no allowed-tools — no capability requirements to check.")
    end

    results =
      Enum.map(requests, fn req ->
        case Egghead.Capability.check(agent_grants, req, %{agent_id: agent_record.id}) do
          :ok -> {:ok, req}
          {:denied, denial} -> {:denied, req, denial}
        end
      end)

    ok_count = Enum.count(results, fn {status, _} -> status == :ok end)
    denied = Enum.filter(results, &match?({:denied, _, _}, &1))

    Enum.each(results, fn
      {:ok, req} ->
        IO.puts("  \e[32m✓\e[0m #{format_request(req)}")

      {:denied, req, denial} ->
        IO.puts("  \e[33m⚠\e[0m #{format_request(req)}")
        IO.puts("    " <> Widgets.dim(denial.message))
    end)

    Enum.each(unknown, fn tok ->
      IO.puts(
        "  \e[31m?\e[0m #{tok}  " <> Widgets.dim("(unknown tool — capability can't be derived)")
      )
    end)

    IO.puts("")

    cond do
      denied == [] and unknown == [] ->
        IO.puts("  \e[32mAll requirements satisfied.\e[0m")

      denied == [] and unknown != [] ->
        IO.puts("  Known requirements satisfied. #{length(unknown)} unknown tools.")

      true ->
        IO.puts(
          "  \e[33m#{length(denied)} missing capabilities.\e[0m (\e[32m#{ok_count} satisfied\e[0m, #{length(unknown)} unknown)"
        )

        IO.puts("")
        IO.puts("  To grant:")

        Enum.each(denied, fn {:denied, req, _} ->
          spec = suggest_spec(req)
          IO.puts("    egghead agents grant #{agent_record.id} '#{spec}'")
        end)
    end
  end

  defp format_request(%Egghead.Capability.Request{} = req) do
    key = "#{req.resource}.#{req.verb}"

    scope_desc =
      case req.scope do
        s when s == %{} -> ""
        %{hosts: hs} -> "{hosts=[#{Enum.join(hs, ",")}]}"
        %{paths: ps} -> "{paths=[#{Enum.join(ps, ",")}]}"
        %{patterns: ps} -> "{patterns=[#{Enum.join(ps, ",")}]}"
        %{cmds: cs} -> "{cmds=[#{Enum.join(cs, ",")}]}"
        _ -> ""
      end

    key <> scope_desc
  end

  defp suggest_spec(%Egghead.Capability.Request{resource: r, verb: v, scope: scope})
       when scope == %{} do
    "#{r}.#{v}"
  end

  defp suggest_spec(%Egghead.Capability.Request{resource: r, verb: v, scope: scope}) do
    pairs =
      Enum.map_join(scope, ",", fn {k, val} ->
        val_str = if is_list(val), do: "[" <> Enum.join(val, ",") <> "]", else: to_string(val)
        "#{k}=#{val_str}"
      end)

    "#{r}.#{v}{#{pairs}}"
  end

  defp do_show(name) do
    Egghead.CLI.prepare_runtime()

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

  # Resolve an agent by id — tries the record store first, falls back
  # to the running agent's state (handles built-in agents like "index").
  defp resolve_agent(agent_id) do
    case Egghead.get_record(agent_id) do
      {:ok, record} when record.class == :agent ->
        record

      _ ->
        case Enum.find(Egghead.list_agents(), &(&1.id == agent_id)) do
          %{capabilities: caps} = agent ->
            # Build a minimal record-like map for report_delta
            %Egghead.Record{
              id: agent.id,
              class: :agent,
              meta: %{"capabilities" => Enum.map(caps, &Egghead.Capability.grant_to_spec/1)}
            }

          nil ->
            nil
        end
    end
  end
end
