defmodule Egghead.Record.AST do
  @moduledoc """
  Parses record body content into a structured AST and extracts
  metadata from it.

  For Markdown, delegates to Earmark (with `wikilinks: true`) and
  walks the resulting AST. Org-mode bodies are parsed by
  `Egghead.Record.OrgParser` (NimbleParsec-based).

  The AST is Earmark's native format: a list of tuples like
  `{tag, attrs, children, meta}` where children can be strings or
  nested tuples.
  """

  alias Egghead.Record

  @type ast_node :: {String.t(), list(), list(), map()} | String.t()

  @doc """
  Parses a Markdown body string into an Earmark AST with wikilinks enabled.

  Returns `{:ok, ast}` or `{:error, reason}`.
  """
  @spec parse_markdown(String.t()) :: {:ok, [ast_node()]} | {:error, term()}
  def parse_markdown(body) do
    # Earmark returns `{:error, ast, warnings}` whenever it emits any
    # warning (common on real-world bodies — e.g. false-positive IAL
    # attribute parsing). The AST in those tuples is usable; treat
    # non-empty error ASTs as successful parses.
    case Earmark.as_ast(body, wikilinks: true) do
      {:ok, ast, _warnings} ->
        {:ok, ast}

      {:error, ast, _warnings} when is_list(ast) and ast != [] ->
        {:ok, ast}

      {:error, _ast, errors} ->
        {:error, {:earmark, errors}}
    end
  end

  @doc """
  Extracts the title from the first `h1` heading in the AST.
  """
  @spec extract_title([ast_node()]) :: String.t() | nil
  def extract_title(ast) do
    ast
    |> Enum.find_value(fn
      {"h1", _attrs, children, _meta} -> text_content(children)
      _ -> nil
    end)
  end

  @doc """
  Extracts an outline of all headings from the AST.

  Returns a list of `%{level: integer, text: string}` maps.
  """
  @spec extract_outline([ast_node()]) :: [%{level: non_neg_integer(), text: String.t()}]
  def extract_outline(ast) do
    ast
    |> Enum.flat_map(fn
      {"h" <> n, _attrs, children, _meta} ->
        case Integer.parse(n) do
          {level, ""} -> [%{level: level, text: text_content(children)}]
          _ -> []
        end

      _ ->
        []
    end)
  end

  @doc """
  Extracts all wikilinks from the AST.

  Returns a list of `%{target: id, display: string | nil, fragment: string | nil}`.
  """
  @spec extract_wikilinks([ast_node()]) :: [Record.wikilink()]
  def extract_wikilinks(ast) do
    walk(ast, [], fn
      {"a", attrs, children, %{wikilink: true}}, acc ->
        href = attrs_get(attrs, "href", "")
        {target, fragment} = split_fragment(href)
        display_text = text_content(children)
        display = if display_text == href, do: nil, else: display_text

        [%{target: target, display: display, fragment: fragment} | acc]

      _, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  @doc """
  Extracts all code blocks from the AST.

  Returns a list of `%{language: string | nil, content: string}` maps.
  """
  @spec extract_code_blocks([ast_node()]) :: [%{language: String.t() | nil, content: String.t()}]
  def extract_code_blocks(ast) do
    walk(ast, [], fn
      {"code", attrs, [content], %{}}, acc ->
        # Only match code blocks (inside <pre>), not inline code
        # Inline code has class "inline", block code has a language class
        class = attrs_get(attrs, "class", "")

        if class != "inline" do
          language = if class == "", do: nil, else: class
          [%{language: language, content: content} | acc]
        else
          # Check if parent is <pre> — but we can't from here,
          # so we skip inline code via the "inline" class
          acc
        end

      _, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  # --- Private helpers ---

  # Recursively walk the AST, applying fun to each node
  defp walk(nodes, acc, fun) when is_list(nodes) do
    Enum.reduce(nodes, acc, fn node, acc -> walk_node(node, acc, fun) end)
  end

  defp walk_node(text, acc, fun) when is_binary(text) do
    fun.(text, acc)
  end

  defp walk_node({_tag, _attrs, children, _meta} = node, acc, fun) do
    acc = fun.(node, acc)
    walk(children, acc, fun)
  end

  defp walk_node(_, acc, _fun), do: acc

  # Extract plain text content from AST children
  defp text_content(children) when is_list(children) do
    children
    |> Enum.map_join("", fn
      text when is_binary(text) -> text
      {_tag, _attrs, nested, _meta} -> text_content(nested)
    end)
    |> String.trim()
  end

  defp split_fragment(href) do
    case String.split(href, "#", parts: 2) do
      [target, fragment] -> {target, fragment}
      [target] -> {target, nil}
    end
  end

  defp attrs_get(attrs, key, default) do
    case List.keyfind(attrs, key, 0) do
      {^key, value} -> value
      nil -> default
    end
  end
end
