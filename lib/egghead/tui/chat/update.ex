defmodule Egghead.TUI.Chat.Update do
  @moduledoc """
  Reducer for the chat screen.

  Two main families of messages flow through here:

    * **Runtime / synthetic** — `{:resize, w, h}`,
      `{:char, c}`, `{:key, ...}`, `{:paste, text}`,
      `{:mouse, ...}`. The runtime in `Egghead.OpenTUI.Runtime`
      delivers these.
    * **Room events** — wrapped in `{:room_event, raw}` by the
      PubSub subscription declared in `Egghead.TUI.Chat`. The
      raw payload is whatever `Egghead.Chat.Room` /
      `Egghead.Chat.Coordinator` broadcast on the room topic.

  All side effects (sending a chat message, halting the runtime)
  flow back as commands the runtime executes — the reducer stays
  pure.
  """

  alias Egghead.OpenTUI.EditBuffer
  alias Egghead.TUI.Chat.{Entry, Model, Paste}
  alias Egghead.TUI.{Completion, SelectList, ThemePicker}

  # Providers checked in order by Completion.refresh/3. First
  # match wins. RoomArgument sits above Command so that once the
  # user has typed "/join " the room picker takes over from the
  # command-name dropdown.
  @completion_providers [
    Completion.RoomArgument,
    Completion.Command,
    Completion.Agent,
    Completion.Record
  ]

  # Canonical command list for the dropdown. Aliases (/exit, /part)
  # are not shown in the dropdown but are accepted on dispatch.
  @chat_command_list [
    %{name: "save", description: "Save transcript as a record"},
    %{name: "copy", description: "Copy transcript to clipboard"},
    %{name: "continue", description: "Grant agents more turns"},
    %{name: "handoff", description: "Handoff an agent's context (space opens picker)"},
    %{name: "join", description: "Join or create a room (type to filter, Enter to join/create)"},
    %{name: "list", description: "List all open rooms"},
    %{name: "drop", description: "Drop the current room"},
    %{name: "mute", description: "Mute an agent (space opens picker)"},
    %{name: "unmute", description: "Unmute a muted agent (space opens picker)"},
    %{name: "tools", description: "Summary of tools available to agents"},
    %{name: "mcp", description: "Summary of MCP servers"},
    %{name: "leave", description: "Return to records (F1)"},
    %{name: "theme", description: "Pick a theme (or /theme <name>)"},
    %{name: "help", description: "Show keybindings & commands"},
    %{name: "quit", description: "Exit the TUI"}
  ]

  @chat_commands %{
    "quit" => :cmd_quit,
    "exit" => :cmd_quit,
    "leave" => :cmd_leave,
    "part" => :cmd_leave,
    "save" => :cmd_save,
    "copy" => :cmd_copy,
    "continue" => :cmd_continue,
    "handoff" => :cmd_handoff,
    "join" => :cmd_join,
    "list" => :cmd_list,
    "rooms" => :cmd_list,
    "drop" => :cmd_drop,
    "mute" => :cmd_mute,
    "unmute" => :cmd_unmute,
    "tools" => :cmd_tools,
    "mcp" => :cmd_mcp,
    "theme" => :cmd_theme,
    "help" => :cmd_help
  }

  @spec update(term(), Model.t()) :: {Model.t(), term()}

  # ---- runtime synthetic --------------------------------------------------

  def update({:resize, w, h}, %Model{} = model) do
    {%{model | width: w, height: h}, :none}
  end

  # ---- theme picker -------------------------------------------------------
  #
  # When the picker is open it consumes every non-resize
  # keystroke until the user commits (Enter) or cancels (Esc).

  def update(msg, %Model{theme_picker: picker} = model) when not is_nil(picker) do
    handle_theme_picker(msg, picker, model)
  end

  # ---- action picker ------------------------------------------------------
  # /join /mute /unmute /handoff — shared SelectList driven by
  # a `{kind, list}` tuple so the commit branch knows which
  # action to dispatch.

  def update(msg, %Model{action_picker: {kind, list}} = model) do
    handle_action_picker(msg, kind, list, model)
  end

  # ---- room events --------------------------------------------------------

  def update({:room_event, event}, %Model{} = model) do
    {handle_room_event(event, model), :none}
  end

  # An unwrapped mailbox message — the Runtime tags anything it
  # can't classify as `{:unknown_msg, raw}`. We just ignore.
  def update({:unknown_msg, _}, %Model{} = model), do: {model, :none}

  # ---- key bindings: leave / send -----------------------------------------

  # Escape / Ctrl+G dismisses an open completion dropdown, the
  # link-nav mode, or falls through as a no-op. Screen switching
  # is F1/F2; clearing input isn't expected Esc behavior.
  def update({:key, key}, %Model{completion: %Completion{}} = model)
      when key in [:escape, :ctrl_g] do
    {%{model | completion: nil}, :none}
  end

  def update({:key, key}, %Model{link_index: idx} = model)
      when idx != nil and key in [:escape, :ctrl_g] do
    {Model.link_deselect(model), :none}
  end

  def update({:key, key}, %Model{} = model) when key in [:escape, :ctrl_g], do: {model, :none}

  # When in link-nav mode, Enter follows the active wikilink to records.
  def update({:key, :enter}, %Model{link_index: idx} = model) when idx != nil do
    case Model.active_link(model) do
      nil ->
        {Model.link_deselect(model), :none}

      target ->
        {Model.link_deselect(model), {:switch_screen, :records, [preferred_id: target]}}
    end
  end

  # When a completion dropdown is open with at least one
  # candidate, Enter first tries to accept — filling the buffer
  # with the focused item. If accepting produces the same
  # buffer (user already has the completed text), Enter falls
  # through to the normal submit path so they don't get stuck
  # re-filling the same value.
  def update(
        {:key, :enter},
        %Model{completion: %Completion{candidates: [_ | _]} = completion} = model
      ) do
    case Completion.accept(completion, model.input) do
      {:edit, new_buffer} ->
        if EditBuffer.to_text(new_buffer) == Model.input_text(model),
          do: enter_submit(model),
          else: {refresh_completion(Model.set_buffer(model, new_buffer)), :none}

      {:submit, _action} ->
        enter_submit(model)

      :noop ->
        enter_submit(model)
    end
  end

  def update({:key, :enter}, %Model{} = model), do: enter_submit(model)

  # Tab accepts the focused completion candidate. Unlike Enter,
  # Tab never dispatches — it's always a fill operation. A
  # no-op accept (already at the completed value) just sits
  # still; the user can then press Enter to submit.
  def update(
        {:key, :tab},
        %Model{completion: %Completion{candidates: [_ | _]} = completion} = model
      ) do
    accept_completion(completion, model)
  end

  # When input is empty, Tab cycles wikilinks in the transcript.
  def update({:key, :tab}, %Model{} = model) do
    if Model.input_empty?(model),
      do: {Model.link_next(model), :none},
      else: {model, :none}
  end

  def update({:key, :shift_tab}, %Model{} = model) do
    if Model.input_empty?(model),
      do: {Model.link_prev(model), :none},
      else: {model, :none}
  end

  # Shift+Enter and Alt+Enter insert a literal newline. Shift+Enter
  # only arrives from Kitty-protocol terminals (iTerm, kitty, ghostty,
  # WezTerm); Alt+Enter is the universal fallback (Apple Terminal,
  # tmux without passthrough, …).
  def update({:key, chord}, %Model{} = model) when chord in [:shift_enter, :alt_enter] do
    {edit(model, &EditBuffer.insert_newline/1), :none}
  end

  # ---- input editing (multi-line via EditBuffer) -------------------------

  def update({:char, c}, %Model{} = model) when is_binary(c) do
    {edit(model, &EditBuffer.insert(&1, c)), :none}
  end

  def update({:key, :backspace}, %Model{} = model) do
    {edit(model, &EditBuffer.delete_before/1), :none}
  end

  def update({:key, :left}, %Model{} = model) do
    {edit(model, &EditBuffer.move_left/1), :none}
  end

  def update({:key, :right}, %Model{} = model) do
    {edit(model, &EditBuffer.move_right/1), :none}
  end

  # Up/Down navigate the completion dropdown when open; otherwise
  # they move the cursor through multiline input (arrow nav).
  def update({:key, :up}, %Model{completion: %Completion{candidates: [_, _ | _]}} = model) do
    {%{model | completion: Completion.move_up(model.completion)}, :none}
  end

  def update({:key, :up}, %Model{} = model) do
    {edit(model, &EditBuffer.move_up/1), :none}
  end

  def update({:key, :down}, %Model{completion: %Completion{candidates: [_, _ | _]}} = model) do
    {%{model | completion: Completion.move_down(model.completion)}, :none}
  end

  def update({:key, :down}, %Model{} = model) do
    {edit(model, &EditBuffer.move_down/1), :none}
  end

  def update({:key, :ctrl_a}, %Model{} = model) do
    {edit(model, &EditBuffer.move_to_line_start/1), :none}
  end

  def update({:key, :ctrl_e}, %Model{} = model) do
    {edit(model, &EditBuffer.move_to_line_end/1), :none}
  end

  # ---- transcript scrolling ------------------------------------------------

  @scroll_step 5

  def update({:key, :page_up}, %Model{} = model),
    do: {scroll_transcript(model, @scroll_step), :none}

  def update({:key, :page_down}, %Model{} = model),
    do: {scroll_transcript(model, -@scroll_step), :none}

  def update({:key, :ctrl_p}, %Model{} = model),
    do: {scroll_transcript(model, @scroll_step), :none}

  def update({:key, :ctrl_n}, %Model{} = model),
    do: {scroll_transcript(model, -@scroll_step), :none}

  # ---- editing continued ---------------------------------------------------

  def update({:key, :ctrl_k}, %Model{} = model) do
    {edit(model, &EditBuffer.kill_to_eol/1), :none}
  end

  def update({:key, :ctrl_u}, %Model{} = model) do
    {edit(model, &EditBuffer.kill_to_bol/1), :none}
  end

  def update({:key, :ctrl_w}, %Model{} = model) do
    {edit(model, &EditBuffer.kill_word/1), :none}
  end

  def update({:key, :alt_b}, %Model{} = model) do
    {edit(model, &EditBuffer.move_word_left/1), :none}
  end

  def update({:key, :alt_f}, %Model{} = model) do
    {edit(model, &EditBuffer.move_word_right/1), :none}
  end

  def update({:key, :alt_d}, %Model{} = model) do
    {edit(model, &EditBuffer.kill_word_forward/1), :none}
  end

  def update({:key, :alt_backspace}, %Model{} = model) do
    {edit(model, &EditBuffer.kill_word/1), :none}
  end

  # Bracketed paste arrives as a single message with newlines
  # preserved. Long pastes (>3 lines OR >150 chars) are wrapped
  # in a `%Paste{}` chip cell so the input box stays uncluttered;
  # short pastes flow inline as plain graphemes.
  def update({:paste, text}, %Model{} = model) when is_binary(text) do
    if Paste.chip_worthy?(text) do
      chip = Paste.build(model.next_paste_id, text)

      model =
        model
        |> Map.put(:next_paste_id, model.next_paste_id + 1)
        |> edit(&EditBuffer.insert_cell(&1, chip))

      {model, :none}
    else
      {edit(model, &EditBuffer.paste(&1, text)), :none}
    end
  end

  # Mouse wheel scrolls the transcript.
  def update({:mouse, %{kind: :wheel_up, press?: true}}, %Model{} = model),
    do: {scroll_transcript(model, 3), :none}

  def update({:mouse, %{kind: :wheel_down, press?: true}}, %Model{} = model),
    do: {scroll_transcript(model, -3), :none}

  def update({:mouse, _}, %Model{} = model), do: {model, :none}
  def update(_other, %Model{} = model), do: {model, :none}

  # ---- room event dispatch ------------------------------------------------

  defp handle_room_event({:user_message, msg}, model) do
    Model.append_entry(model, Entry.user(msg.sender.name, msg.content))
    |> auto_scroll()
    |> clear_status()
  end

  defp handle_room_event({:agent_message, msg}, model) do
    model
    |> Model.finalize_stream(msg.sender.id)
    |> Model.drop_stream(msg.sender.id)
    |> set_agent_status(msg.sender.id, :idle)
    |> update_agent_ctx(msg.sender.id, msg)
    |> clear_status()
  end

  defp handle_room_event({:agent_streaming, _room_id, agent_id, delta}, model) do
    model
    |> Model.apply_stream_delta(agent_id, delta)
    |> set_agent_status(agent_id, :active)
    |> bump_anim()
    |> auto_scroll()
  end

  defp handle_room_event({:agent_tool_call, _room_id, agent_id, name, input}, model) do
    text = format_tool_call(name, input)
    display = display_name(agent_id, model)

    # Flush any in-progress streamed text first — otherwise the agent's
    # pre-tool-call text would concatenate with its post-tool-call text
    # when the next delta arrives, producing things like
    # "Sure, calling:There it is..." with no separator.
    model
    |> Model.finalize_stream(agent_id)
    |> Model.append_entry(Entry.action(agent_id, display, text))
  end

  defp handle_room_event(
         {:agent_tool_denied, _room_id, agent_id, tool_name, input, denial},
         model
       ) do
    display = display_name(agent_id, model)
    text = format_denial(agent_id, tool_name, input, denial)

    model
    |> Model.finalize_stream(agent_id)
    |> Model.append_entry(Entry.denial(agent_id, display, text, denial))
  end

  # Streaming tool output (stdout chunks from shell_exec, etc.).
  # Appends each chunk as a muted :action entry so long-running
  # commands don't look hung. Rolling merge: if the last transcript
  # entry is our own tool_output for the same tool_use_id, extend
  # its text rather than adding a new line.
  defp handle_room_event(
         {:agent_tool_output, _room_id, agent_id, tool_name, tool_use_id, chunk},
         model
       ) do
    trimmed = String.trim_trailing(chunk)

    if trimmed == "" do
      model
    else
      display = display_name(agent_id, model)
      merge_tool_output(model, agent_id, display, tool_name, tool_use_id, trimmed)
    end
  end

  defp handle_room_event({:agents_activated, _count}, model) do
    # The Coordinator just decided which agents are about to
    # speak; we don't yet know their ids individually. The first
    # streaming delta from each will clear them from the pending
    # set. For now we just bump the anim frame so the ellipsis
    # ticks.
    %{model | anim_frame: model.anim_frame + 1}
  end

  defp handle_room_event({:agent_passed, agent_id}, model) do
    display = display_name(agent_id, model)
    # Random flavor per /pass event. The picked text is stored on the
    # Entry so subsequent re-renders use the same string — no need to
    # seed the pick deterministically.
    flavor = Egghead.Chat.PassActions.pick()

    model
    |> Model.drop_stream(agent_id)
    |> Model.append_entry(Entry.action(agent_id, display, flavor))
    |> set_agent_status(agent_id, :idle)
  end

  defp handle_room_event({:agent_mentions, _room_id, _from, _to, _content}, model), do: model

  defp handle_room_event(:budget_exhausted, model) do
    %{
      model
      | status_message: "We've been chatting for a bit. Anything to add? If not, /continue."
    }
  end

  defp handle_room_event(:continued, model), do: clear_status(model)

  defp handle_room_event({:system_notice, text}, model) do
    Model.append_entry(model, Entry.system(text))
  end

  defp handle_room_event({:agent_joined, agent_id}, model) do
    if Enum.any?(model.agents, &(&1.id == agent_id)) do
      model
    else
      name = agent_id |> String.split("/") |> List.last() |> String.capitalize()
      presence = %Model.AgentPresence{id: agent_id, name: name, status: :idle}
      %{model | agents: model.agents ++ [presence]}
    end
  end

  defp handle_room_event({:agent_left, agent_id}, model) do
    %{model | agents: Enum.reject(model.agents, &(&1.id == agent_id))}
  end

  defp handle_room_event({:agent_handoff, _room_id, agent_id, delib_id}, model) do
    display = display_name(agent_id, model)

    msg =
      Entry.system("#{display} is back with fresh context — saved [[#{delib_id}]]")

    Model.append_entry(model, msg)
  end

  defp handle_room_event({:room_stopped, room_id}, model) do
    if room_id == model.room_id do
      default = Egghead.default_room()

      model
      |> Model.append_entry(Entry.system("Room #{room_id} was dropped."))
      |> Model.switch_room(default)
    else
      model
    end
  end

  defp handle_room_event(_other, model), do: model

  # ---- helpers ------------------------------------------------------------

  defp enter_submit(%Model{} = model) do
    text = Model.input_text(model)

    cond do
      Model.input_empty?(model) ->
        {model, :none}

      String.starts_with?(text, "/") ->
        dispatch_command(text, model)

      model.room_id == nil ->
        {model, :none}

      true ->
        room_id = model.room_id
        cmd = {:exec, fn -> send_message(room_id, text) end}
        {%{Model.clear_input(model) | scroll: 0}, cmd}
    end
  end

  # Apply a pure EditBuffer transformation to the model's input,
  # then re-detect completion triggers and refresh candidates.
  defp edit(%Model{input: buffer} = model, fun) when is_function(fun, 1) do
    model
    |> Model.set_buffer(fun.(buffer))
    |> refresh_completion()
  end

  # After every input edit, update the completion dropdown state.
  # Three of the commands that open modal pickers (/theme, /mute,
  # /unmute, /handoff) short-circuit at an exact trigger match
  # since those don't compose with free-form args — the user
  # just picks one thing. /join is driven by Completion.RoomArgument
  # so the user can type a brand-new room name while seeing
  # matching existing rooms.
  defp refresh_completion(model) do
    text = Model.input_text(model)

    cond do
      String.downcase(text) == "/theme " ->
        %{Model.clear_input(model) | completion: nil, theme_picker: ThemePicker.open()}

      action_spec = match_action_trigger(text, model) ->
        {kind, items} = action_spec
        open_action_picker(Model.clear_input(model), kind, items)

      true ->
        completion_model =
          Map.merge(model, %{
            completion_commands: @chat_command_list,
            agents: agents_by_recency(model)
          })

        completion = Completion.refresh(@completion_providers, model.input, completion_model)
        %{model | completion: completion}
    end
  end

  @action_triggers %{
    "/mute " => :mute,
    "/unmute " => :unmute,
    "/handoff " => :handoff
  }

  # Resolve the trigger AND the candidate list in one pass so
  # `refresh_completion` can cleanly fall through to the normal
  # completion dropdown when a picker would be empty.
  defp match_action_trigger(text, model) do
    lower = String.downcase(text)

    case Enum.find_value(@action_triggers, fn {trigger, kind} ->
           if lower == trigger, do: kind
         end) do
      nil ->
        nil

      kind ->
        case action_items(kind, model) do
          [] -> nil
          items -> {kind, items}
        end
    end
  end

  defp open_action_picker(model, kind, items) do
    opts = [title: action_title(kind), hint: action_hint(kind)]
    list = SelectList.new(items, opts)
    %{model | completion: nil, action_picker: {kind, list}}
  end

  defp action_title(:mute), do: "mute"
  defp action_title(:unmute), do: "unmute"
  defp action_title(:handoff), do: "handoff"

  defp action_hint(:mute), do: "↑↓ select · enter mute · esc cancel"
  defp action_hint(:unmute), do: "↑↓ select · enter unmute · esc cancel"
  defp action_hint(:handoff), do: "↑↓ select · enter handoff · esc cancel"

  defp action_items(:mute, %Model{agents: agents}) do
    Enum.map(agents, fn a -> %{id: a.id, label: a.name, hint: a.id} end)
  end

  defp action_items(:unmute, %Model{room_id: nil}), do: []

  defp action_items(:unmute, %Model{room_id: room_id, agents: agents}) do
    muted =
      try do
        Egghead.Chat.Room.muted(room_id) |> MapSet.new()
      rescue
        _ -> MapSet.new()
      catch
        _, _ -> MapSet.new()
      end

    agents
    |> Enum.filter(&MapSet.member?(muted, &1.id))
    |> Enum.map(fn a -> %{id: a.id, label: a.name, hint: a.id} end)
  end

  defp action_items(:handoff, %Model{agents: agents}) do
    Enum.map(agents, fn a -> %{id: a.id, label: a.name, hint: a.id} end)
  end

  # ---- completion acceptance ---------------------------------------------

  defp accept_completion(%Completion{} = completion, model) do
    case Completion.accept(completion, model.input) do
      {:edit, new_buffer} ->
        {refresh_completion(Model.set_buffer(model, new_buffer)), :none}

      {:submit, _action} ->
        # Currently no provider returns :submit — left here so a
        # future "dispatch on select" provider (e.g. pick agent
        # → immediately send) has a clear hook.
        {model, :none}

      :noop ->
        {model, :none}
    end
  end

  # Return agents sorted by last activity in the transcript
  # (most recent first). Agents that haven't spoken fall to the
  # end in roster order.
  defp agents_by_recency(%Model{agents: agents, transcript: transcript}) do
    # Build a map of agent_id → index of last transcript entry.
    last_seen =
      transcript
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {entry, idx}, acc ->
        case entry do
          %Entry{kind: k, sender_id: sid} when k in [:agent, :action] and sid != nil ->
            Map.put(acc, sid, idx)

          _ ->
            acc
        end
      end)

    agents
    |> Enum.sort_by(fn a ->
      case Map.get(last_seen, a.id) do
        nil -> {1, a.id}
        idx -> {0, -idx}
      end
    end)
  end

  # Scroll is lines-from-bottom: 0 = pinned to newest.
  # Positive delta scrolls up (older), negative scrolls down (newer).
  defp scroll_transcript(%Model{} = model, delta) do
    # Only clamp the lower bound here — scroll is measured in rendered
    # lines, not transcript entries, and a single multi-paragraph agent
    # message can render to many lines. The view clamps against the
    # exact rendered row count on every frame, so over-scrolling is
    # invisible to the user; capping here against `length(transcript)`
    # would silently limit history to entry count instead of line count.
    new_scroll = max(model.scroll + delta, 0)
    %{model | scroll: new_scroll}
  end

  # Keep the view pinned to bottom when new content arrives,
  # but only if the user hasn't scrolled up to read history.
  defp auto_scroll(%Model{scroll: 0} = model), do: model
  defp auto_scroll(model), do: model

  defp bump_anim(%Model{} = model), do: %{model | anim_frame: model.anim_frame + 1}

  defp clear_status(%Model{} = model), do: %{model | status_message: nil}

  defp set_agent_status(%Model{agents: agents} = model, agent_id, status) do
    agents =
      Enum.map(agents, fn
        %Model.AgentPresence{id: ^agent_id} = a -> %{a | status: status}
        a -> a
      end)

    %{model | agents: agents}
  end

  # Extract context info from the Message's inline usage field.
  # The usage map carries :input_tokens, :output_tokens, :session_tokens
  # (cumulative lifetime), :current_context_tokens (current footprint),
  # :context_window, and :context_pct directly. Pressure display uses
  # current context, not cumulative. When the window is unknown (local
  # models, providers that don't advertise it) we still track tokens —
  # the view renders "N tok" with no bar rather than a bogus 0%.
  defp update_agent_ctx(%Model{agents: agents} = model, agent_id, msg) do
    case Map.get(msg, :usage) do
      %{context_window: cw, current_context_tokens: cct} when is_integer(cw) and cw > 0 ->
        pct = Float.round(cct / cw * 100, 1)
        set_agent_ctx(model, agents, agent_id, pct, cw, cct)

      %{current_context_tokens: cct} when is_integer(cct) ->
        set_agent_ctx(model, agents, agent_id, 0.0, 0, cct)

      _ ->
        model
    end
  end

  defp set_agent_ctx(model, agents, agent_id, pct, cw, cct) do
    agents =
      Enum.map(agents, fn
        %Model.AgentPresence{id: ^agent_id} = a ->
          %{a | ctx_pct: pct, ctx_window: cw, ctx_tokens: cct}

        a ->
          a
      end)

    %{model | agents: agents}
  end

  defp display_name(agent_id, %Model{agents: agents}) do
    case Enum.find(agents, &(&1.id == agent_id)) do
      %{name: name} -> name
      _ -> agent_id |> String.split("/") |> List.last() |> String.capitalize()
    end
  end

  defp format_tool_call(name, input) when is_map(input) do
    summary =
      input
      |> Enum.map(fn {k, v} -> "#{k}=#{inspect_compact(v)}" end)
      |> Enum.join(" ")

    "uses #{name} #{summary}" |> String.trim()
  end

  defp format_tool_call(name, _), do: "uses #{name}"

  # Merge a streamed tool_output chunk with the last transcript
  # entry if it's the same tool invocation (matched via tool_use_id
  # stored in Entry metadata). Otherwise append a new entry.
  defp merge_tool_output(model, agent_id, display, tool_name, tool_use_id, chunk) do
    transcript = model.transcript

    case List.last(transcript) do
      %Entry{kind: :action, metadata: %{tool_output: true, tool_use_id: ^tool_use_id}} = last ->
        updated = %{last | text: last.text <> "\n" <> chunk}
        %{model | transcript: List.replace_at(transcript, -1, updated)}

      _ ->
        entry = %Entry{
          kind: :action,
          sender_id: agent_id,
          sender_name: display,
          text: "#{tool_name}: #{chunk}",
          timestamp: DateTime.utc_now(),
          metadata: %{tool_output: true, tool_use_id: tool_use_id}
        }

        Model.append_entry(model, entry)
    end
  end

  defp format_denial(agent_id, tool_name, input, denial) do
    input_summary =
      case input do
        %{} = m ->
          m
          |> Enum.map(fn {k, v} -> "#{k}=#{inspect_compact(v)}" end)
          |> Enum.join(" ")

        _ ->
          ""
      end

    tried = String.trim("tried #{tool_name} #{input_summary}")
    reason = "denied (#{denial.code}): #{denial.message}"

    grant_line =
      if denial.suggested_grant do
        "→ egghead agent grant #{agent_id} '#{denial.suggested_grant}'"
      else
        nil
      end

    [tried, reason, grant_line]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp inspect_compact(v) when is_binary(v) do
    if String.length(v) > 40, do: String.slice(v, 0, 37) <> "...", else: v
  end

  defp inspect_compact(v), do: inspect(v)

  # Wrapped in a try so a transient room exit doesn't take the
  # whole TUI down. The :exec runner does NOT crash the runtime
  # on a returned error tuple, so we surface it as a status flash
  # later if needed.
  defp send_message(room_id, text) do
    try do
      Egghead.chat(room_id, text)
      :no_msg
    catch
      :exit, _ -> :no_msg
      _, _ -> :no_msg
    end
  end

  # ---- slash commands ------------------------------------------------------

  defp dispatch_command(text, model) do
    [raw_cmd | args] =
      text
      |> String.trim_leading("/")
      |> String.split(" ", parts: 2)

    cmd_name = String.downcase(raw_cmd)
    arg = List.first(args, "")

    case Map.get(@chat_commands, cmd_name) do
      nil ->
        model =
          Model.append_entry(
            Model.clear_input(model),
            Entry.system("Unknown command: /#{cmd_name}")
          )

        {model, :none}

      handler ->
        apply_command(handler, arg, model)
    end
  end

  defp apply_command(:cmd_quit, _arg, model) do
    {Model.clear_input(model), :halt}
  end

  defp apply_command(:cmd_leave, _arg, model) do
    {Model.clear_input(model), {:switch_screen, :records, []}}
  end

  defp apply_command(:cmd_save, _arg, model) do
    room_id = model.room_id

    cmd =
      exec_async(room_id, fn ->
        case Egghead.chat_save(room_id) do
          {:ok, record_id} ->
            broadcast_system_notice(room_id, "Transcript saved → [[#{record_id}]]")

          {:error, reason} ->
            broadcast_system_notice(room_id, "Save failed: #{inspect(reason)}")

          _ ->
            broadcast_system_notice(room_id, "Save failed")
        end
      end)

    {Model.clear_input(model), cmd}
  end

  defp apply_command(:cmd_copy, _arg, model) do
    transcript = Egghead.Chat.Room.get_transcript(model.room_id)

    {note, _} =
      case transcript do
        [] ->
          {"Transcript is empty", :ok}

        msgs ->
          body = Egghead.Chat.Room.format_transcript(msgs)
          {"Transcript copied to clipboard", Egghead.OpenTUI.Clipboard.copy(body)}
      end

    model =
      model
      |> Model.clear_input()
      |> Model.append_entry(Entry.system(note))

    {model, :none}
  end

  defp apply_command(:cmd_continue, _arg, model) do
    room_id = model.room_id

    cmd =
      {:exec,
       fn ->
         try do
           Egghead.chat_continue(room_id)
           :no_msg
         catch
           _, _ -> :no_msg
         end
       end}

    model =
      model
      |> Model.clear_input()
      |> Model.append_entry(Entry.system("Budget renewed — agents may continue"))

    {model, cmd}
  end

  defp apply_command(:cmd_handoff, arg, model) do
    target = String.trim(arg)

    cond do
      target == "" ->
        msg = Entry.system("Usage: /handoff <agent>")
        {Model.append_entry(Model.clear_input(model), msg), :none}

      model.room_id == nil ->
        msg = Entry.system("/handoff requires an active room")
        {Model.append_entry(Model.clear_input(model), msg), :none}

      true ->
        # Run the handoff off the runtime process — `Egghead.handoff/2`
        # is a `GenServer.call` with a 300s timeout that summarises the
        # agent's session via the LLM. If we ran it inside `:exec`, the
        # runtime loop would be blocked for the full summary duration
        # and no input would be processed. `exec_async/2` fires a
        # supervised Task and returns immediately; the outcome
        # broadcasts back as a `:system_notice` on the room topic, which
        # the chat screen already renders via its PubSub subscription.
        room_id = model.room_id

        cmd =
          exec_async(room_id, fn ->
            case Egghead.handoff(target, room_id: room_id) do
              {:ok, delib_id} ->
                broadcast_system_notice(
                  room_id,
                  "Handoff complete for #{target} — saved [[#{delib_id}]]"
                )

              {:ok, delib_id, _response} ->
                broadcast_system_notice(
                  room_id,
                  "Handoff complete for #{target} — saved [[#{delib_id}]]"
                )

              {:error, reason} ->
                broadcast_system_notice(
                  room_id,
                  "Handoff failed for #{target}: #{inspect(reason)}"
                )
            end
          end)

        model =
          model
          |> Model.clear_input()
          |> Model.append_entry(Entry.system("Handoff initiated for #{target}…"))

        {model, cmd}
    end
  end

  defp apply_command(:cmd_join, arg, model) do
    target = String.trim(arg)

    cond do
      target == "" ->
        msg = Entry.system("Usage: /join <room-id-or-transcript-id>")
        {Model.append_entry(Model.clear_input(model), msg), :none}

      target == model.room_id ->
        msg = Entry.system("Already in #{target}.")
        {Model.append_entry(Model.clear_input(model), msg), :none}

      true ->
        case resolve_join_target(target) do
          {:ok, room_id} ->
            # Switch the model to the new room. Preserves :width and
            # :height (Model.init would reset them to 80x24, which
            # shrinks the visible frame until the next resize event).
            # The runtime observes the changed :room_id in
            # subscriptions/1 and automatically resubscribes.
            {Model.switch_room(model, room_id), :none}

          {:error, reason} ->
            msg = Entry.system("Cannot join #{inspect(target)}: #{reason}")
            {Model.append_entry(Model.clear_input(model), msg), :none}
        end
    end
  end

  defp apply_command(:cmd_list, _arg, model) do
    rooms = Egghead.list_rooms()
    default = Egghead.default_room()

    lines =
      if rooms == [] do
        ["No rooms open."]
      else
        Enum.map(rooms, fn id ->
          marker = if id == default, do: " (default)", else: ""

          info =
            try do
              state = Egghead.Chat.Room.get_state(id)
              agents = length(state.agents || [])
              msgs = state.message_count || 0
              " — #{agents} agents, #{msgs} messages"
            catch
              _, _ -> ""
            end

          "  #{id}#{marker}#{info}"
        end)
      end

    text = ["Rooms:" | lines] |> Enum.join("\n")
    msg = Entry.system(text)
    {Model.append_entry(Model.clear_input(model), msg), :none}
  end

  defp apply_command(:cmd_drop, arg, model) do
    no_save = String.contains?(arg, "--no-save")

    cond do
      model.room_id == Egghead.default_room() ->
        msg = Entry.system("Cannot drop the default room.")
        {Model.append_entry(Model.clear_input(model), msg), :none}

      true ->
        room_id = model.room_id
        default = Egghead.default_room()

        cmd =
          {:exec,
           fn ->
             Egghead.stop_room(room_id, no_save: no_save)
             :no_msg
           end}

        {Model.switch_room(Model.clear_input(model), default), cmd}
    end
  end

  defp apply_command(:cmd_mute, arg, model) do
    target = String.trim(arg)

    if target == "" do
      {Model.append_entry(Model.clear_input(model), Entry.system("Usage: /mute <agent>")), :none}
    else
      cmd =
        {:exec,
         fn ->
           Egghead.Chat.Room.mute(model.room_id, target)
           :no_msg
         end}

      {Model.clear_input(model), cmd}
    end
  end

  defp apply_command(:cmd_unmute, arg, model) do
    target = String.trim(arg)

    if target == "" do
      {Model.append_entry(Model.clear_input(model), Entry.system("Usage: /unmute <agent>")),
       :none}
    else
      cmd =
        {:exec,
         fn ->
           Egghead.Chat.Room.unmute(model.room_id, target)
           :no_msg
         end}

      {Model.clear_input(model), cmd}
    end
  end

  defp apply_command(:cmd_help, _arg, model) do
    help_text = """
    Key bindings: ⏎ send │ ⇧⏎ newline │ @agent mention │ [[record]] link │ Tab accept
    Commands: /save /copy /continue /handoff <agent> /join <room> /list /drop /mute /unmute /tools /mcp /leave /help /quit
    Navigation: F1 records │ F2 chat │ Esc dismiss
    Copy: hold Shift + drag to select text\
    """

    model =
      model
      |> Model.clear_input()
      |> Model.append_entry(Entry.system(help_text))

    {model, :none}
  end

  defp apply_command(:cmd_tools, _arg, model) do
    model =
      model
      |> Model.clear_input()
      |> Model.append_entry(Entry.system(Egghead.TUI.ToolCatalog.tools_summary()))

    {model, :none}
  end

  defp apply_command(:cmd_mcp, _arg, model) do
    model =
      model
      |> Model.clear_input()
      |> Model.append_entry(Entry.system(Egghead.TUI.ToolCatalog.mcp_summary()))

    {model, :none}
  end

  defp apply_command(:cmd_theme, arg, model) do
    model = Model.clear_input(model)
    name = String.trim(arg)

    case name do
      "" ->
        {%{model | theme_picker: ThemePicker.open()}, :none}

      _ ->
        case ThemePicker.apply(name) do
          :ok ->
            {Model.append_entry(model, Entry.system("Theme set: #{name}")), :none}

          {:error, :not_found} ->
            {Model.append_entry(model, Entry.system("Unknown theme: #{name}")), :none}
        end
    end
  end

  # ---- theme picker routing ----------------------------------------------

  defp handle_theme_picker(msg, picker, model) do
    case ThemePicker.handle_key(msg, picker) do
      {_picker, status} when status in [:committed, :cancelled] ->
        {%{model | theme_picker: nil}, :none}

      {updated, :open} ->
        {%{model | theme_picker: updated}, :none}
    end
  end

  # ---- action picker routing ----------------------------------------------

  defp handle_action_picker(msg, kind, list, model) do
    case SelectList.handle_key(msg, list) do
      {_, :cancelled} ->
        {%{model | action_picker: nil}, :none}

      {_, {:committed, item}} ->
        dispatch_action(kind, item, %{model | action_picker: nil})

      {updated, {:cursor_moved, _item}} ->
        {%{model | action_picker: {kind, updated}}, :none}

      {updated, :open} ->
        {%{model | action_picker: {kind, updated}}, :none}
    end
  end

  # Dispatch the committed action. Each branch mirrors the
  # corresponding `apply_command/3` path so the behaviour (async
  # exec, system notices, transcript annotations) stays identical
  # whether the user typed "/join <name>" or arrowed through the
  # picker.

  defp dispatch_action(:room, %{id: target}, model) do
    cond do
      target == model.room_id ->
        {Model.append_entry(model, Entry.system("Already in #{target}.")), :none}

      true ->
        case resolve_join_target(target) do
          {:ok, room_id} ->
            {Model.switch_room(model, room_id), :none}

          {:error, reason} ->
            {Model.append_entry(model, Entry.system("Cannot join #{inspect(target)}: #{reason}")),
             :none}
        end
    end
  end

  defp dispatch_action(:mute, %{id: target}, %Model{room_id: room_id} = model)
       when is_binary(room_id) do
    cmd =
      {:exec,
       fn ->
         Egghead.Chat.Room.mute(room_id, target)
         :no_msg
       end}

    {model, cmd}
  end

  defp dispatch_action(:unmute, %{id: target}, %Model{room_id: room_id} = model)
       when is_binary(room_id) do
    cmd =
      {:exec,
       fn ->
         Egghead.Chat.Room.unmute(room_id, target)
         :no_msg
       end}

    {model, cmd}
  end

  defp dispatch_action(:handoff, %{id: target}, %Model{room_id: room_id} = model)
       when is_binary(room_id) do
    cmd =
      exec_async(room_id, fn ->
        case Egghead.handoff(target, room_id: room_id) do
          {:ok, delib_id} ->
            broadcast_system_notice(
              room_id,
              "Handoff complete for #{target} — saved [[#{delib_id}]]"
            )

          {:ok, delib_id, _response} ->
            broadcast_system_notice(
              room_id,
              "Handoff complete for #{target} — saved [[#{delib_id}]]"
            )

          {:error, reason} ->
            broadcast_system_notice(
              room_id,
              "Handoff failed for #{target}: #{inspect(reason)}"
            )
        end
      end)

    {Model.append_entry(model, Entry.system("Handoff initiated for #{target}…")), cmd}
  end

  defp dispatch_action(_kind, _item, model), do: {model, :none}

  # Fire a side-effectful function off the runtime process. The
  # `:exec` body spawns a supervised Task and returns immediately so
  # the runtime loop stays free to process input, PubSub events, and
  # redraws. Progress and outcomes are delivered back via
  # `broadcast_system_notice/2`, which the chat screen receives via
  # its subscription to the room's PubSub topic.
  defp exec_async(room_id, fun) do
    {:exec,
     fn ->
       Task.Supervisor.start_child(Egghead.Tool.TaskSupervisor, fn ->
         try do
           fun.()
         rescue
           e -> broadcast_system_notice(room_id, "Command failed: #{Exception.message(e)}")
         catch
           :exit, reason ->
             broadcast_system_notice(room_id, "Command failed: #{inspect(reason)}")
         end
       end)

       :no_msg
     end}
  end

  defp broadcast_system_notice(nil, _text), do: :ok

  defp broadcast_system_notice(room_id, text) do
    Phoenix.PubSub.broadcast(
      Egghead.PubSub,
      Egghead.Chat.Room.topic(room_id),
      {:system_notice, text}
    )
  end

  @valid_room_name ~r/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/

  # Resolve a `/join` argument to a room id. Tries, in order:
  # (1) a live room with that exact id; (2) a saved transcript record;
  # (3) create a new room with that name (IRC semantics).
  defp resolve_join_target(target) do
    cond do
      Egghead.room_exists?(target) ->
        {:ok, target}

      true ->
        candidate = if String.starts_with?(target, "chat/"), do: target, else: "chat/#{target}"

        case Egghead.Chat.Room.from_transcript(candidate) do
          {:ok, room_id} ->
            {:ok, room_id}

          {:error, :not_found} ->
            create_room_if_valid(target)

          {:error, :wrong_class} ->
            {:error, "record exists but is not a transcript"}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
    end
  end

  defp create_room_if_valid(name) do
    cond do
      String.length(name) > 64 ->
        {:error, "room name too long (max 64 characters)"}

      not Regex.match?(@valid_room_name, name) ->
        {:error, "room name must be alphanumeric (hyphens and underscores allowed)"}

      true ->
        case Egghead.create_room(id: name) do
          {:ok, room_id} -> {:ok, room_id}
          {:error, reason} -> {:error, "could not create room: #{inspect(reason)}"}
        end
    end
  end
end
