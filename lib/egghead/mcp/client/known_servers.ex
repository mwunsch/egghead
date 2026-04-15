defmodule Egghead.MCP.Client.KnownServers do
  @moduledoc """
  Loader for the curated MCP server registry at
  `priv/mcp/known_servers.yml`.

  A known server is a pre-declared name → spec mapping the user can
  install without having to author `requires:` themselves. Templates
  with `<path>` placeholders are substituted at `egghead tools mcp
  add` time from user input.
  """

  @doc "Returns the full registry as a map of `name => spec`."
  def all do
    load()
  end

  @doc "Lookup a single server by name."
  def lookup(name) when is_binary(name) do
    Map.get(load(), name)
  end

  @doc """
  Expand a spec's `<path>` placeholders from a substitutions map.

  Applies to both the `command` string and any `requires_template`
  paths. If the spec has no templates and no `<path>` in the command,
  returns the spec unchanged.
  """
  def substitute(spec, subs) when is_map(spec) and is_map(subs) do
    command = substitute_str(Map.get(spec, "command", ""), subs)

    requires =
      case Map.get(spec, "requires") do
        nil ->
          case Map.get(spec, "requires_template") do
            nil -> []
            template -> substitute_requires(template, subs)
          end

        reqs ->
          reqs
      end

    spec
    |> Map.put("command", command)
    |> Map.put("requires", requires)
    |> Map.delete("requires_template")
  end

  defp substitute_requires(template, subs) when is_list(template) do
    Enum.map(template, fn entry -> substitute_requires_entry(entry, subs) end)
  end

  defp substitute_requires_entry(entry, subs) when is_binary(entry) do
    substitute_str(entry, subs)
  end

  defp substitute_requires_entry(entry, subs) when is_map(entry) and map_size(entry) == 1 do
    [{verb, scope}] = Map.to_list(entry)
    %{verb => substitute_scope(scope, subs)}
  end

  defp substitute_requires_entry(other, _subs), do: other

  defp substitute_scope(scope, subs) when is_map(scope) do
    Map.new(scope, fn
      {k, v} when is_list(v) -> {k, Enum.map(v, &substitute_str(&1, subs))}
      {k, v} when is_binary(v) -> {k, substitute_str(v, subs)}
      other -> other
    end)
  end

  defp substitute_scope(other, _), do: other

  defp substitute_str(str, subs) when is_binary(str) do
    Enum.reduce(subs, str, fn {k, v}, acc ->
      String.replace(acc, "<#{k}>", to_string(v))
    end)
  end

  defp substitute_str(other, _), do: other

  # --- loading ---

  defp load do
    path = Path.join(:code.priv_dir(:egghead), "mcp/known_servers.yml")

    case File.read(path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, data} when is_map(data) -> data
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end
end
