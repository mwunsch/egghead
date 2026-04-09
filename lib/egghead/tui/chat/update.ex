defmodule Egghead.TUI.Chat.Update do
  @moduledoc """
  Reducer for the chat screen. Phase 6a only handles resize and
  the Esc-to-leave shortcut; everything else lands in 6c+.
  """

  alias Egghead.TUI.Chat.Model

  @spec update(term(), Model.t()) :: {Model.t(), term()}
  def update({:resize, w, h}, %Model{} = model) do
    {%{model | width: w, height: h}, :none}
  end

  # Esc returns to records mode. The bare-ESC NIF fix from Phase
  # 5e (`commit 5ef436a`) makes a single `:escape` event reliably
  # distinguishable from the start of a CSI escape sequence.
  def update({:key, :escape}, %Model{} = model) do
    {model, {:switch_screen, :records, []}}
  end

  def update(_msg, %Model{} = model), do: {model, :none}
end
