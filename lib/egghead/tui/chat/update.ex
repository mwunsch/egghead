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
  alias Egghead.TUI.Chat.{Entry, Mentions, Model, Paste}

  # Canonical command list for the dropdown. Aliases (/exit, /part)
  # are not shown in the dropdown but are accepted on dispatch.
  @chat_command_list [
    %{name: "save", description: "Save transcript as a record"},
    %{name: "continue", description: "Grant agents more turns"},
    %{name: "handoff", description: "Handoff an agent's context"},
    %{name: "leave", description: "Return to records (F1)"},
    %{name: "help", description: "Show keybindings & commands"},
    %{name: "quit", description: "Exit the TUI"}
  ]

  @chat_commands %{
    "quit" => :cmd_quit,
    "exit" => :cmd_quit,
    "leave" => :cmd_leave,
    "part" => :cmd_leave,
    "save" => :cmd_save,
    "continue" => :cmd_continue,
    "handoff" => :cmd_handoff,
    "help" => :cmd_help
  }

  @spec update(term(), Model.t()) :: {Model.t(), term()}

  # ---- runtime synthetic --------------------------------------------------

  def update({:resize, w, h}, %Model{} = model) do
    {%{model | width: w, height: h}, :none}
  end

  # ---- room events --------------------------------------------------------

  def update({:room_event, event}, %Model{} = model) do
    {handle_room_event(event, model), :none}
  end

  # An unwrapped mailbox message — the Runtime tags anything it
  # can't classify as `{:unknown_msg, raw}`. We just ignore.
  def update({:unknown_msg, _}, %Model{} = model), do: {model, :none}

  # ---- key bindings: leave / send -----------------------------------------

  # Escape dismisses an open mention dropdown. Otherwise it's a
  # no-op — screen switching uses F1/F2, and clearing input isn't
  # expected Esc behavior. Future: interrupt active agents.
  def update({:key, :escape}, %Model{command: %{candidates: [_ | _]}} = model) do
    {%{model | command: nil}, :none}
  end

  def update({:key, :escape}, %Model{mention: %Mentions.Context{candidates: [_ | _]}} = model) do
    {%{model | mention: nil}, :none}
  end

  def update({:key, :escape}, %Model{} = model), do: {model, :none}

  # When the command dropdown is open, Enter fills the input (same as Tab).
  def update({:key, :enter}, %Model{command: %{candidates: [_ | _]} = ctx} = model) do
    chosen = Enum.at(ctx.candidates, ctx.selected)
    new_buffer = EditBuffer.from_text("/#{chosen.name} ")
    {refresh_completion(Model.set_buffer(model, new_buffer)), :none}
  end

  def update({:key, :enter}, %Model{} = model) do
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
        {Model.clear_input(model), cmd}
    end
  end

  # Tab completes the selected command or mention candidate.
  def update({:key, :tab}, %Model{command: %{candidates: [_ | _]} = ctx} = model) do
    chosen = Enum.at(ctx.candidates, ctx.selected)
    new_buffer = EditBuffer.from_text("/#{chosen.name} ")
    {refresh_completion(Model.set_buffer(model, new_buffer)), :none}
  end

  def update({:key, :tab}, %Model{mention: %Mentions.Context{candidates: [_ | _]} = ctx} = model) do
    new_buffer = Mentions.accept(model.input, ctx)
    {refresh_completion(Model.set_buffer(model, new_buffer)), :none}
  end

  def update({:key, :tab}, %Model{} = model), do: {model, :none}

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

  # Up/Down navigate the command or mention dropdown when open.
  def update({:key, :up}, %Model{command: %{candidates: [_, _ | _]} = ctx} = model) do
    n = length(ctx.candidates)
    {%{model | command: %{ctx | selected: rem(ctx.selected - 1 + n, n)}}, :none}
  end

  def update({:key, :up}, %Model{mention: %Mentions.Context{candidates: [_, _ | _]} = ctx} = model) do
    {%{model | mention: Mentions.move_up(ctx)}, :none}
  end

  def update({:key, :up}, %Model{} = model) do
    {edit(model, &EditBuffer.move_up/1), :none}
  end

  def update({:key, :down}, %Model{command: %{candidates: [_, _ | _]} = ctx} = model) do
    n = length(ctx.candidates)
    {%{model | command: %{ctx | selected: rem(ctx.selected + 1, n)}}, :none}
  end

  def update({:key, :down}, %Model{mention: %Mentions.Context{candidates: [_, _ | _]} = ctx} = model) do
    {%{model | mention: Mentions.move_down(ctx)}, :none}
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

  # Mouse and unrecognized input are silently swallowed in 6c.
  def update({:mouse, _}, %Model{} = model), do: {model, :none}
  def update(_other, %Model{} = model), do: {model, :none}

  # ---- room event dispatch ------------------------------------------------

  defp handle_room_event({:user_message, msg}, model) do
    Model.append_entry(model, Entry.user(msg.sender.name, msg.content))
    |> clear_status()
  end

  defp handle_room_event({:agent_message, msg}, model) do
    model
    # The streaming path may already have committed paragraphs;
    # finalize_stream flushes whatever is left in the per-agent
    # buffer, then we drop the stream entirely. The :agent_message
    # broadcast carries the *complete* text, but our streaming
    # accumulator already holds the same bytes — finalizing avoids
    # double-rendering.
    |> Model.finalize_stream(msg.sender.id)
    |> Model.drop_stream(msg.sender.id)
    |> clear_status()
  end

  defp handle_room_event({:agent_streaming, _room_id, agent_id, delta}, model) do
    Model.apply_stream_delta(model, agent_id, delta)
  end

  defp handle_room_event({:agent_tool_call, _room_id, agent_id, name, input}, model) do
    text = format_tool_call(name, input)
    name = display_name(agent_id, model)
    Model.append_entry(model, Entry.action(agent_id, name, text))
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
    Model.drop_stream(model, agent_id)
  end

  defp handle_room_event({:agent_mentions, _room_id, _from, _to}, model), do: model

  defp handle_room_event(:budget_exhausted, model) do
    %{model | status_message: "budget exhausted — /continue to grant more turns"}
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

  defp handle_room_event(_other, model), do: model

  # ---- helpers ------------------------------------------------------------

  # Apply a pure EditBuffer transformation to the model's input,
  # then re-detect the mention sigil under the cursor and populate
  # candidates from the live agent roster / record store.
  defp edit(%Model{input: buffer} = model, fun) when is_function(fun, 1) do
    model
    |> Model.set_buffer(fun.(buffer))
    |> refresh_completion()
  end

  # After every input edit, decide whether to show the mention
  # dropdown or the command dropdown (mutually exclusive).
  defp refresh_completion(model) do
    text = Model.input_text(model)

    cond do
      String.starts_with?(text, "/") and not String.contains?(text, "\n") ->
        refresh_command(model, text)

      true ->
        model
        |> Map.put(:command, nil)
        |> refresh_mention()
    end
  end

  defp refresh_command(model, text) do
    needle = text |> String.trim_leading("/") |> String.downcase()

    candidates =
      @chat_command_list
      |> Enum.filter(fn cmd -> String.starts_with?(cmd.name, needle) end)

    ctx = %{candidates: candidates, selected: 0}
    %{model | command: ctx, mention: nil}
  end

  defp refresh_mention(%Model{input: buffer} = model) do
    case Mentions.detect(buffer) do
      nil ->
        %{model | mention: nil}

      %Mentions.Context{kind: :agent, prefix: prefix} = ctx ->
        candidates = Mentions.rank_agents(agents_by_recency(model), prefix)
        %{model | mention: %{ctx | candidates: candidates}}

      %Mentions.Context{kind: :record, prefix: prefix} = ctx ->
        candidates = Mentions.rank_records(safe_recent_records(), prefix)
        %{model | mention: %{ctx | candidates: candidates}}
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

  # Records sorted by last modified — `Egghead.recent/1` returns
  # them in `:updated` desc order already.
  defp safe_recent_records do
    try do
      Egghead.recent(limit: 100)
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  defp clear_status(%Model{} = model), do: %{model | status_message: nil}

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
        model = Model.append_entry(Model.clear_input(model), Entry.system("Unknown command: /#{cmd_name}"))
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
      {:exec,
       fn ->
         try do
           case Egghead.chat_save(room_id) do
             {:ok, record} ->
               {:inject, {:room_event, {:system_notice, "Transcript saved as #{record.id}"}}}

             _ ->
               {:inject, {:room_event, {:system_notice, "Save failed"}}}
           end
         catch
           _, _ -> {:inject, {:room_event, {:system_notice, "Save failed"}}}
         end
       end}

    {Model.clear_input(model), cmd}
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

    if target == "" do
      model = Model.append_entry(Model.clear_input(model), Entry.system("Usage: /handoff <agent>"))
      {model, :none}
    else
      cmd =
        {:exec,
         fn ->
           try do
             Egghead.handoff(target)
             :no_msg
           catch
             _, _ -> :no_msg
           end
         end}

      model =
        model
        |> Model.clear_input()
        |> Model.append_entry(Entry.system("Handoff initiated for #{target}"))

      {model, cmd}
    end
  end

  defp apply_command(:cmd_help, _arg, model) do
    help_text = """
    Key bindings: ⏎ send │ ⇧⏎ newline │ @agent mention │ [[record]] link │ Tab accept
    Commands: /save /continue /handoff <agent> /leave /help /quit
    Navigation: F1 records │ F2 chat │ Esc dismiss\
    """

    model =
      model
      |> Model.clear_input()
      |> Model.append_entry(Entry.system(help_text))

    {model, :none}
  end
end
