defmodule Egghead.TUI.Chat do
  @moduledoc """
  Chat screen as an `Egghead.OpenTUI.Runtime` behaviour, mirroring
  the shape of `Egghead.TUI.Records`.

  Phase 6a is a placeholder — the screen renders a static panel
  and exits back to records on Esc. Phases 6c onward fill in the
  transcript, streaming, input, presence sidebar, and slash
  commands.

  Although this module declares the runtime behaviour, it is not
  launched directly. The shell at `Egghead.TUI.App` wraps it and
  the records screen, dispatching messages to whichever screen is
  active.
  """

  @behaviour Egghead.OpenTUI.Runtime

  alias Egghead.TUI.Chat.{Model, Update, View}

  @impl true
  def init(opts), do: {Model.init(opts), :none}

  @impl true
  def update(msg, model), do: Update.update(msg, model)

  @impl true
  def view(model), do: View.render(model)

  @impl true
  def subscriptions(_model), do: [:keys]
end
