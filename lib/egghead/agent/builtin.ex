defmodule Egghead.Agent.Builtin do
  @moduledoc """
  Loads built-in agent records from `priv/agents/`.

  Built-ins exist so a fresh install always has someone to talk to
  (Index) and so the eval pipeline always has a grader (Judge). Each
  one is a real Markdown record with frontmatter and a disposition,
  parsed at runtime through the same parser the record store uses.

  A user record with `class: agent` and a matching `id:` shadows the
  built-in: the supervisor refuses to spawn a synthetic copy when a
  store-backed equivalent exists. This is the single override
  mechanism — there is no separate "config the built-in" path.

  Built-ins do not fix a `model:`. The frontmatter omits it on
  purpose so the configured `default_model` (or its fallback) is
  resolved at spawn time, the same way any user agent without an
  explicit model is resolved.
  """

  alias Egghead.Record
  alias Egghead.Record.Parser

  @doc """
  Returns every built-in agent record, parsed and ready to spawn.
  Resolved fresh on each call so config changes (e.g. updating
  `default_model`) take effect on the next sync without a restart.
  """
  @spec all() :: [Record.t()]
  def all do
    priv_dir() |> Path.join("*.md") |> Path.wildcard() |> Enum.flat_map(&load/1)
  end

  @doc """
  Fetch a single built-in by id, e.g. `"index"` or `"judge"`. Returns
  `nil` if no priv file declares that id.
  """
  @spec fetch(String.t()) :: Record.t() | nil
  def fetch(id) when is_binary(id) do
    Enum.find(all(), &(&1.id == id))
  end

  @doc """
  Returns the list of reserved built-in agent ids. Used by code that
  needs to distinguish "synthetic, no record" agents from store-backed
  ones (e.g. `Agent.Supervisor.sync_agents_local/2`).
  """
  @spec ids() :: [String.t()]
  def ids do
    Enum.map(all(), & &1.id)
  end

  defp priv_dir do
    case :code.priv_dir(:egghead) do
      {:error, :bad_name} -> Path.expand("priv", File.cwd!())
      path -> Path.join(to_string(path), "agents")
    end
  end

  defp load(path) do
    case File.read(path) do
      {:ok, content} ->
        case Parser.parse(content, source_path: nil) do
          {:ok, record} ->
            [%Record{record | source_path: nil}]

          {:error, _reason} ->
            []
        end

      {:error, _} ->
        []
    end
  end
end
