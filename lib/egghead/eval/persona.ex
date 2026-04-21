defmodule Egghead.Eval.Persona do
  @moduledoc """
  A task-bundled agent definition loaded from `priv/eval/personas/`.

  Personas are the cast of a MARBLE-style task — specialized agent
  profiles shipped alongside tasks for reproducible benchmark runs.
  When a task run uses `roster: :task`, the runner spawns one
  transient `Egghead.Agent` process per persona referenced by the
  task, hydrated from these files.

  Personas live in `priv/` as markdown records with frontmatter. They
  are never written into the user's record store. Transient agent
  processes are stopped and discarded at the end of a run.

  The file format matches a regular `class: agent` record:

      ---
      id: researcher-1
      class: agent
      model: "{configured_default}"
      capabilities: [records.read]
      tags: [persona, research]
      source: marble/configs/test_config_research/profile_1.yaml#agent1
      ---

      I am a researcher with a background in…
  """

  alias Egghead.Record

  @doc """
  Bundled personas root (`priv/eval/personas`).
  """
  @spec bundled_dir() :: String.t()
  def bundled_dir do
    Path.join(:code.priv_dir(:egghead), "eval/personas")
  end

  @doc """
  Loads a persona by id from the bundled personas directory. Returns
  a hydrated `Egghead.Record{class: :agent}` ready to pass to
  `Egghead.Agent.Supervisor.start_agent/3`.
  """
  @spec fetch(String.t()) :: {:ok, Record.t()} | {:error, :not_found}
  def fetch(id) do
    case find_file(id) do
      nil -> {:error, :not_found}
      path -> load_file(path)
    end
  end

  @doc """
  Loads multiple personas by id. Returns `{:ok, records}` if all
  resolve, or `{:error, {:missing, ids}}` with the list that didn't.
  """
  @spec fetch_all([String.t()]) ::
          {:ok, [Record.t()]} | {:error, {:missing, [String.t()]}}
  def fetch_all(ids) when is_list(ids) do
    {found, missing} =
      Enum.reduce(ids, {[], []}, fn id, {found, missing} ->
        case fetch(id) do
          {:ok, record} -> {[record | found], missing}
          {:error, :not_found} -> {found, [id | missing]}
        end
      end)

    case missing do
      [] -> {:ok, Enum.reverse(found)}
      ids -> {:error, {:missing, Enum.reverse(ids)}}
    end
  end

  defp find_file(id) do
    bundled_dir()
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.find(fn path ->
      derived_id(path) == id
    end)
  end

  defp derived_id(path) do
    path
    |> Path.relative_to(bundled_dir())
    |> Path.rootname()
    |> Path.basename()
  end

  @doc false
  def load_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, frontmatter, disposition} <- split_frontmatter(body) do
      {:ok, build_record(frontmatter, disposition, path)}
    end
  end

  defp split_frontmatter("---\n" <> rest) do
    case String.split(rest, "\n---\n", parts: 2) do
      [front, body] ->
        case YamlElixir.read_from_string(front) do
          {:ok, map} when is_map(map) -> {:ok, map, String.trim_leading(body)}
          other -> {:error, {:yaml, other}}
        end

      _ ->
        {:error, :missing_frontmatter_close}
    end
  end

  defp split_frontmatter(_), do: {:error, :missing_frontmatter}

  defp build_record(fm, body, path) do
    id = Map.get(fm, "id") || derived_id(path)

    meta =
      fm
      |> Map.drop(["id", "class", "tags", "title", "links"])
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    %Record{
      id: id,
      title: Map.get(fm, "title") || id,
      class: :agent,
      tags: Map.get(fm, "tags", []) |> Enum.map(&to_string/1),
      links: Map.get(fm, "links", []) |> Enum.map(&to_string/1),
      meta: meta,
      body: body,
      source_path: nil
    }
  end
end
