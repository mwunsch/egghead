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

  alias Egghead.OpenTUI.Readline
  alias Egghead.TUI.Chat.{Entry, Model}

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

  def update({:key, :escape}, %Model{input: ""} = model) do
    {model, {:switch_screen, :records, []}}
  end

  def update({:key, :escape}, %Model{} = model) do
    {Model.clear_input(model), :none}
  end

  def update({:key, :enter}, %Model{input: ""} = model), do: {model, :none}

  def update({:key, :enter}, %Model{room_id: nil} = model), do: {model, :none}

  def update({:key, :enter}, %Model{} = model) do
    text = model.input
    room_id = model.room_id
    cmd = {:exec, fn -> send_message(room_id, text) end}
    {Model.clear_input(model), cmd}
  end

  # ---- input editing (single-line in 6c; replaced by EditBuffer in 6d) ---

  def update({:char, c}, %Model{} = model) when is_binary(c) do
    {input, cursor} = Readline.insert(model.input, model.cursor, c)
    {Model.set_input(model, input, cursor), :none}
  end

  def update({:key, :backspace}, %Model{} = model) do
    {input, cursor} = Readline.delete_before(model.input, model.cursor)
    {Model.set_input(model, input, cursor), :none}
  end

  def update({:key, :left}, %Model{} = model) do
    {_, cursor} = Readline.move_left(model.input, model.cursor)
    {Model.set_input(model, model.input, cursor), :none}
  end

  def update({:key, :right}, %Model{} = model) do
    {_, cursor} = Readline.move_right(model.input, model.cursor)
    {Model.set_input(model, model.input, cursor), :none}
  end

  def update({:key, :ctrl_a}, %Model{} = model) do
    {Model.set_input(model, model.input, 0), :none}
  end

  def update({:key, :ctrl_e}, %Model{} = model) do
    {Model.set_input(model, model.input, String.length(model.input)), :none}
  end

  def update({:key, :ctrl_k}, %Model{} = model) do
    {input, cursor} = Readline.kill_to_eol(model.input, model.cursor)
    {Model.set_input(model, input, cursor), :none}
  end

  def update({:key, :ctrl_u}, %Model{} = model) do
    {input, cursor} = Readline.kill_to_bol(model.input, model.cursor)
    {Model.set_input(model, input, cursor), :none}
  end

  def update({:key, :ctrl_w}, %Model{} = model) do
    {input, cursor} = Readline.kill_word(model.input, model.cursor)
    {Model.set_input(model, input, cursor), :none}
  end

  def update({:key, :alt_b}, %Model{} = model) do
    {_, cursor} = Readline.move_word_left(model.input, model.cursor)
    {Model.set_input(model, model.input, cursor), :none}
  end

  def update({:key, :alt_f}, %Model{} = model) do
    {_, cursor} = Readline.move_word_right(model.input, model.cursor)
    {Model.set_input(model, model.input, cursor), :none}
  end

  def update({:key, :alt_d}, %Model{} = model) do
    {input, _} = Readline.kill_word_forward(model.input, model.cursor)
    {Model.set_input(model, input, model.cursor), :none}
  end

  def update({:key, :alt_backspace}, %Model{} = model) do
    {input, cursor} = Readline.kill_word(model.input, model.cursor)
    {Model.set_input(model, input, cursor), :none}
  end

  # Pasting in 6c just inserts the text inline, stripping any
  # newlines (single-line input). 6d will preserve them via
  # EditBuffer.
  def update({:paste, text}, %Model{} = model) when is_binary(text) do
    flat = String.replace(text, "\n", " ")
    {input, cursor} = Readline.insert(model.input, model.cursor, flat)
    {Model.set_input(model, input, cursor), :none}
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
end
