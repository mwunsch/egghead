defmodule Egghead.TUI.ThemePicker do
  @moduledoc """
  Theme picker — wraps `Egghead.TUI.SelectList` with
  theme-specific side effects.

  Up/Down live-preview via `Egghead.Theme.set/1`; Enter commits
  via `Egghead.Theme.commit/1` (writes config); Esc reverts to
  the theme that was committed when the picker opened. The
  caret marks the row whose theme is saved in config —
  selection focus is carried by the selection-bg highlight.
  """

  alias Egghead.Theme
  alias Egghead.TUI.SelectList

  @type status :: :open | :committed | :cancelled

  @type t :: %__MODULE__{list: SelectList.t(), original: String.t()}
  defstruct [:list, :original]

  # ---- Lifecycle ----------------------------------------------------------

  @doc "Open the picker. The list is loaded once at open-time."
  @spec open() :: t()
  def open do
    themes = Theme.list()
    committed = Theme.committed_name()

    items =
      Enum.map(themes, fn t ->
        %{id: t.name, label: t.display_name, hint: mode_badge(t.mode)}
      end)

    list =
      SelectList.new(items,
        title: "theme",
        marker_id: committed,
        cursor_id: committed
      )

    %__MODULE__{list: list, original: committed}
  end

  @doc "Apply a named theme directly without opening the picker. Persists to config."
  @spec apply(String.t()) :: :ok | {:error, term()}
  def apply(name) when is_binary(name), do: Theme.commit(name)

  # ---- Input --------------------------------------------------------------

  @spec handle_key(term(), t()) :: {t(), status()}
  def handle_key(msg, %__MODULE__{list: list} = picker) do
    case SelectList.handle_key(msg, list) do
      {list, {:cursor_moved, item}} ->
        Theme.set(item.id)
        {%{picker | list: list}, :open}

      {list, {:committed, item}} ->
        Theme.commit(item.id)
        {%{picker | list: list}, :committed}

      {list, :cancelled} ->
        Theme.set(picker.original)
        {%{picker | list: list}, :cancelled}

      {list, :open} ->
        {%{picker | list: list}, :open}
    end
  end

  # ---- View ---------------------------------------------------------------

  @spec height(t()) :: non_neg_integer()
  def height(%__MODULE__{list: list}), do: SelectList.height(list)

  @spec view(t(), pos_integer()) :: Egghead.OpenTUI.View.tree()
  def view(%__MODULE__{list: list}, width), do: SelectList.view(list, width)

  # ---- Internals ----------------------------------------------------------

  defp mode_badge(:dark), do: "·dark"
  defp mode_badge(:light), do: "·light"
end
