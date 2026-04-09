defmodule Egghead.OpenTUI.View do
  @moduledoc """
  View tree constructors for the Elm-style runtime.

  A view is a nested tuple tree:

      {:vbox, opts, [child, ...]}
      {:hbox, opts, [child, ...]}
      {:text, content, opts}
      {:fill, opts}
      {:overlay, [child, ...]}      # z-stacked, last on top
      :nothing                       # empty placeholder

  `opts` is a map. Common keys:

    * `:flex` — proportional weight along the parent's main axis
    * `:height` — fixed cell height (vbox children)
    * `:width` — fixed cell width (hbox children)
    * `:fg` / `:bg` — color binaries (see `Egghead.OpenTUI.Colors`)
    * `:attrs` — text attribute bitfield (see `Egghead.OpenTUI.Attrs`).
      OR-ed combination of bold/dim/italic/underline/blink/strikethrough.
      Forwarded to `Bridge.draw_text/7` as the `attributes: u32` arg.
    * `:padding` — non-negative integer (uniform) or
      `{top, right, bottom, left}`
    * `:align` — `:left | :center | :right` (text only;
      currently parsed but not enforced by the renderer)

  All constructors normalize their input into the same tuple
  shape so `Layout.arrange/2` and `Renderer.draw/3` can pattern-
  match without worrying about whether opts came in as a map or
  keyword list.
  """

  @type opts :: map()
  @type leaf ::
          {:text, String.t(), opts()}
          | {:fill, opts()}
          | {:cursor, opts()}
  @type container ::
          {:vbox, opts(), [tree()]}
          | {:hbox, opts(), [tree()]}
          | {:overlay, [tree()]}
  @type tree :: container() | leaf() | :nothing

  # ---- containers ---------------------------------------------------------

  @doc "Vertical stack. Children are placed top-to-bottom."
  @spec vbox([tree()] | keyword()) :: tree()
  def vbox(children) when is_list(children) do
    if Keyword.keyword?(children) do
      vbox_kw(children)
    else
      {:vbox, %{}, children}
    end
  end

  @spec vbox(keyword(), [tree()]) :: tree()
  def vbox(opts, children) when is_list(opts) and is_list(children) do
    {:vbox, normalize_opts(opts), children}
  end

  defp vbox_kw(opts) do
    {children, rest} = Keyword.pop(opts, :children, [])
    {:vbox, normalize_opts(rest), children}
  end

  @doc "Horizontal stack. Children are placed left-to-right."
  @spec hbox([tree()] | keyword()) :: tree()
  def hbox(children) when is_list(children) do
    if Keyword.keyword?(children) do
      hbox_kw(children)
    else
      {:hbox, %{}, children}
    end
  end

  @spec hbox(keyword(), [tree()]) :: tree()
  def hbox(opts, children) when is_list(opts) and is_list(children) do
    {:hbox, normalize_opts(opts), children}
  end

  defp hbox_kw(opts) do
    {children, rest} = Keyword.pop(opts, :children, [])
    {:hbox, normalize_opts(rest), children}
  end

  @doc """
  Stack children at the same rect; later children draw on top.
  Use for modals, dropdowns, scrollbars.
  """
  @spec overlay([tree()]) :: tree()
  def overlay(children) when is_list(children) do
    {:overlay, children}
  end

  # ---- leaves -------------------------------------------------------------

  @doc "Text run. Truncated to its allotted width by the renderer."
  @spec text(String.t(), keyword()) :: leaf()
  def text(content, opts \\ []) when is_binary(content) do
    {:text, content, normalize_opts(opts)}
  end

  @doc "Empty rectangle filled with `:bg`. Useful for backgrounds and gutters."
  @spec fill(keyword()) :: leaf()
  def fill(opts \\ []) do
    {:fill, normalize_opts(opts)}
  end

  @doc "Empty placeholder; arrangement skips it entirely."
  @spec nothing() :: tree()
  def nothing, do: :nothing

  @doc """
  Marks where the terminal's text cursor should be placed.

  A `:cursor` leaf occupies zero columns of layout space, so it
  can sit between two text leaves in an hbox without shifting
  them. The renderer extracts its assigned `(x, y)` and calls
  `Bridge.set_cursor_position/4` to place the OS-level cursor
  there. If multiple cursor leaves appear in a single tree, the
  last one wins.

  When no cursor leaf is in the tree, the renderer hides the
  cursor for that frame.
  """
  @spec cursor(keyword()) :: leaf()
  def cursor(opts \\ []) do
    {:cursor, normalize_opts(opts)}
  end

  # ---- helpers ------------------------------------------------------------

  defp normalize_opts(opts) when is_map(opts), do: opts
  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
end
