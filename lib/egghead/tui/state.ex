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

    # Date display format for the list rows: :relative or :iso
    date_format: :relative,

    # Link navigation
    link_index: nil,
    nav_history: [],
    preview_links: [],

    # Preview metadata for scroll clamping (computed when preview is set)
    preview_total_lines: 0,

    # Command autocomplete
    command_mode: false,
    command_input: "",
    command_selected: 0,
    # Argument captured from the last execute_command (e.g. "scout" from
    # "/handoff scout"). Cleared on next command entry.
    command_arg: "",

    # Chat mode
    # The room currently bound to chat mode (nil when in records mode).
    chat_room_id: nil,
    # Display-ordered list of chat_entry() — see chat_render.ex
    chat_messages: [],
    # %{agent_id => %{name, text, started_at}} for streaming/in-progress
    chat_in_progress: %{},
    # Current draft message (latest line — earlier lines are in extras)
    chat_input: "",
    # Earlier lines from Ctrl+J multi-line composition (in order)
    chat_input_extra_lines: [],
    # Transcript scroll offset; 0 = pinned to bottom (auto-follow new msgs)
    chat_scroll: 0,
    # Cached count of rendered transcript lines for scroll math
    chat_total_lines: 0,
    # Presence: [%{id, name, model, ctx_pct, status}]
    chat_agents: [],
    # Latest budget snapshot from room events: %{remaining, total} | nil
    chat_budget: nil,
    # Active ghost-text mention completion suffix, or nil
    chat_ghost: nil
  ]
end
