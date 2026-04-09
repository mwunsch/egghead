defmodule Egghead.TUI.Chat do
  @moduledoc """
  Chat screen as an `Egghead.OpenTUI.Runtime` behaviour, mirroring
  the shape of `Egghead.TUI.Records`.

  The screen subscribes to its room's PubSub topic, hydrates the
  existing transcript on entry, and renders streaming agent
  output live as it arrives. Esc on an empty input returns to
  records mode.

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
  def subscriptions(%Model{room_id: nil}), do: [:keys]

  def subscriptions(%Model{room_id: room_id}) do
    [
      :keys,
      {:pubsub, Egghead.Chat.Room.topic(room_id), &{:room_event, &1}}
    ]
  end
end
