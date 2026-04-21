defmodule Egghead.TUI.Records do
  @moduledoc """
  Records-list screen as an `Egghead.OpenTUI.Runtime` behaviour.

  Wires together `Egghead.TUI.Records.Model`,
  `Egghead.TUI.Records.Update`, and `Egghead.TUI.Records.View`
  so the runtime can drive the screen via four pure callbacks.
  """

  @behaviour Egghead.OpenTUI.Runtime

  alias Egghead.TUI.Records.{Model, Update, View}

  @impl true
  def init(_opts) do
    {Model.init(), :none}
  end

  @impl true
  def update(msg, model) do
    Update.update(msg, model)
  end

  @impl true
  def view(model) do
    View.render(model)
  end

  @impl true
  def subscriptions(_model) do
    [
      :keys,
      {:pubsub, Egghead.RecordStore.records_topic(), &{:record_event, &1}},
      {:pubsub, Egghead.Theme.topic(), & &1}
    ]
  end
end
