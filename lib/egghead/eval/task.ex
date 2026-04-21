defmodule Egghead.Eval.Task do
  @moduledoc """
  An eval task — a prompt plus a milestone checklist used to grade
  multi-agent runs against it.

  Tasks are bundled with Egghead in `priv/eval/tasks/<category>/*.md`.
  They are not records in the user's store; they are fixtures that ship
  with the binary. Loading from an external directory is supported via
  `load_from/1` for user-authored tasks.

  The task file format is markdown with frontmatter:

      ---
      id: research/profile-1
      category: research
      difficulty: medium
      required_capabilities: [records.read]
      personas: [researcher-1, researcher-2]
      dialogue_mode: open
      milestones:
        - "Identify overlapping research interests"
        - "Propose a concrete collaborative direction"
      ---

      # Task title

      Task prompt text that will be posted to the chat room.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          category: atom(),
          difficulty: atom() | nil,
          required_capabilities: [String.t()],
          personas: [String.t()],
          dialogue_mode: atom(),
          milestones: [String.t()],
          prompt: String.t(),
          source_path: String.t() | nil
        }

  @enforce_keys [:id, :category, :milestones, :prompt]
  defstruct [
    :id,
    :title,
    :description,
    :category,
    :difficulty,
    :source_path,
    required_capabilities: [],
    personas: [],
    dialogue_mode: :open,
    milestones: [],
    prompt: ""
  ]

  @doc """
  Returns the bundled-tasks root directory (`priv/eval/tasks`).
  """
  @spec bundled_dir() :: String.t()
  def bundled_dir do
    Path.join(:code.priv_dir(:egghead), "eval/tasks")
  end

  @doc """
  Loads all tasks from the bundled tasks directory.
  """
  @spec list() :: [t()]
  def list, do: load_from(bundled_dir())

  @doc """
  Loads all tasks from a directory tree. Walks recursively and parses
  every `.md` file as a task.
  """
  @spec load_from(String.t()) :: [t()]
  def load_from(dir) do
    if File.dir?(dir) do
      dir
      |> Path.join("**/*.md")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        case load_file(path) do
          {:ok, task} -> [task]
          {:error, _} -> []
        end
      end)
      |> Enum.sort_by(& &1.id)
    else
      []
    end
  end

  @doc """
  Fetches one task by id from the bundled directory.
  """
  @spec fetch(String.t()) :: {:ok, t()} | {:error, :not_found}
  def fetch(id) do
    case Enum.find(list(), &(&1.id == id)) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  @doc """
  Parses a single task file. Exposed for tests.
  """
  @spec load_file(String.t()) :: {:ok, t()} | {:error, term()}
  def load_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, frontmatter, prompt} <- split_frontmatter(body) do
      {:ok, build_task(frontmatter, prompt, path)}
    end
  end

  defp split_frontmatter("---\n" <> rest) do
    case String.split(rest, "\n---\n", parts: 2) do
      [front, body] ->
        case YamlElixir.read_from_string(front) do
          {:ok, map} when is_map(map) -> {:ok, map, String.trim_leading(body)}
          {:ok, _} -> {:error, :invalid_frontmatter}
          {:error, reason} -> {:error, {:yaml, reason}}
        end

      _ ->
        {:error, :missing_frontmatter_close}
    end
  end

  defp split_frontmatter(_), do: {:error, :missing_frontmatter}

  defp build_task(fm, prompt, path) do
    %__MODULE__{
      id: Map.get(fm, "id") || derive_id(path),
      title: Map.get(fm, "title") || extract_title(prompt),
      description: Map.get(fm, "description"),
      category: Map.get(fm, "category", "general") |> atomize(),
      difficulty: Map.get(fm, "difficulty") |> maybe_atomize(),
      required_capabilities: Map.get(fm, "required_capabilities", []) |> Enum.map(&to_string/1),
      personas: Map.get(fm, "personas", []) |> Enum.map(&to_string/1),
      dialogue_mode: Map.get(fm, "dialogue_mode", "open") |> atomize(),
      milestones: Map.get(fm, "milestones", []) |> Enum.map(&to_string/1),
      prompt: prompt,
      source_path: path
    }
  end

  defp derive_id(path) do
    path
    |> Path.relative_to(bundled_dir())
    |> Path.rootname()
  end

  defp extract_title(body) do
    body
    |> String.split("\n", parts: 2)
    |> List.first()
    |> case do
      "# " <> title -> String.trim(title)
      _ -> nil
    end
  end

  defp atomize(val) when is_atom(val), do: val
  defp atomize(val) when is_binary(val), do: String.to_atom(val)

  defp maybe_atomize(nil), do: nil
  defp maybe_atomize(val), do: atomize(val)
end
