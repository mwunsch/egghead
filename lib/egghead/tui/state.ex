defmodule Egghead.TUI.State do
  @moduledoc "Top-level state for the Egghead TUI."

  defstruct [
    # Terminal
    width: 80,
    height: 24,

    # Mode
    mode: :records,

    # Records mode
    query: "",
    all_records: [],
    results: [],
    selected: 0,
    scroll_offset: 0,
    preview: nil,
    preview_scroll: 0,
    show_all_classes: false,

    # Agents
    agents: [],

    # Command autocomplete
    command_mode: false,
    command_input: "",
    command_selected: 0
  ]
end
