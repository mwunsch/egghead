defmodule Egghead.TUI.Records.Update do
  @moduledoc """
  Reducer for the records-list screen.

  `update/2` takes a message produced by the runtime
  (`Egghead.OpenTUI.Runtime`) and a current model
  (`Egghead.TUI.Records.Model`) and returns a new model plus a
  command. Pure function — no I/O. Side effects (record loads,
  $EDITOR spawns, etc.) are returned as commands.

  Phase 5b key bindings:

    * `↑ / ↓`           — move selection in the list
    * `Ctrl+F`           — toggle class filter (durable / all)
    * `Ctrl+T`           — toggle date format (relative / iso)
    * `PgUp / PgDn`      — scroll preview pane ±5 lines
    * `Ctrl+N / Ctrl+P`  — scroll preview pane ±5 lines (emacs)
    * `printable char`   — append to filter
    * `backspace`        — pop last filter char
    * `escape / ctrl+c`  — quit

  Later sub-phases add `enter` (open in $EDITOR / follow link),
  `tab` (cycle wikilinks), `/` (command palette), and so on.
  """

  alias Egghead.TUI.Records.Model

  @preview_scroll_step 5

  @spec update(term(), Model.t()) :: {Model.t(), term()}
  def update({:key, :ctrl_c}, model), do: {model, :halt}

  def update({:key, :escape}, model), do: {model, :halt}

  def update({:key, :up}, model), do: {move_selection(model, -1), :none}
  def update({:key, :down}, model), do: {move_selection(model, +1), :none}

  def update({:key, :ctrl_f}, model), do: {Model.toggle_class_filter(model), :none}
  def update({:key, :ctrl_t}, model), do: {Model.toggle_date_format(model), :none}

  def update({:key, :page_up}, model),
    do: {Model.scroll_preview(model, -@preview_scroll_step), :none}

  def update({:key, :page_down}, model),
    do: {Model.scroll_preview(model, +@preview_scroll_step), :none}

  def update({:key, :ctrl_p}, model),
    do: {Model.scroll_preview(model, -@preview_scroll_step), :none}

  def update({:key, :ctrl_n}, model),
    do: {Model.scroll_preview(model, +@preview_scroll_step), :none}

  def update({:key, :backspace}, model) do
    new_filter = String.slice(model.filter, 0, max(String.length(model.filter) - 1, 0))
    {set_filter(model, new_filter), :none}
  end

  def update({:char, c}, model) when is_binary(c) do
    {set_filter(model, model.filter <> c), :none}
  end

  def update(_other, model), do: {model, :none}

  # ---- internals ----------------------------------------------------------

  defp set_filter(model, filter) do
    %{model | filter: filter}
    |> Model.refilter()
    |> Model.clamp_selection()
    |> Model.hydrate_selection()
  end

  defp move_selection(model, delta) do
    n = length(model.filtered)

    new_sel =
      cond do
        n == 0 -> 0
        true -> model.selection |> Kernel.+(delta) |> max(0) |> min(n - 1)
      end

    %{model | selection: new_sel}
    |> Model.hydrate_selection()
  end
end
