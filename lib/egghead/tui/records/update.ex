defmodule Egghead.TUI.Records.Update do
  @moduledoc """
  Reducer for the records-list screen.

  `update/2` takes a message produced by the runtime
  (`Egghead.OpenTUI.Runtime`) and a current model
  (`Egghead.TUI.Records.Model`) and returns a new model plus a
  command. Pure function — no I/O. Side effects (record loads,
  $EDITOR spawns, etc.) are returned as commands the runtime
  executes.

  Key bindings (records mode):

    Selection / scroll
      ↑ / ↓              move selection in the list
      Enter              edit selected record (or create + edit
                          when the phantom create row is selected,
                          or follow active link in link-nav mode,
                          or run command in command mode)
      PgUp / PgDn        scroll preview pane ±5 lines
      Ctrl+N / Ctrl+P    scroll preview pane ±5 lines (emacs)
      Mouse wheel        scroll preview pane ±3 lines

    Link navigation (preview pane wikilinks + backlinks)
      Tab                enter link mode and select next link
      Shift+Tab          enter link mode and select previous link
      Enter (link mode)  follow active link, push current onto
                          nav history
      ESC                exit link mode / command mode
      Backspace          if filter is empty, pop nav history

    Command palette
      /                  enter command mode (when filter empty)
      ↑ / ↓ (cmd mode)   move dropdown selection
      Enter (cmd mode)   execute selected command

    Toggles
      Ctrl+T             toggle date format (relative / iso)

    Search bar (readline-style)
      printable char     insert at cursor
      ← / →              move cursor left / right
      Ctrl+A             move cursor to beginning
      Ctrl+E             move cursor to end
      Ctrl+K             kill from cursor to end of line
      Ctrl+U             kill from beginning of line to cursor
      Ctrl+W             kill the previous word
      Alt+B (Option+B)   move cursor backward one word
      Alt+F (Option+F)   move cursor forward one word
      Alt+D (Option+D)   kill the next word
      Alt+Backspace      kill the previous word (alt to Ctrl+W)
      Backspace          delete char before cursor

  Quit is `Ctrl+Q` (or `Ctrl+C`); both are intercepted by
  `Egghead.OpenTUI.Runtime` directly so screens don't see them.
  Ctrl+Z is also intercepted by the runtime to suspend the
  process to the background. Ctrl+L is accepted as a no-op
  redraw hint (we redraw every frame anyway).

  ## Synthetic messages

  The runtime also dispatches:

    * `{:resize, w, h}` — whenever the terminal dimensions change.
    * `{:editor_returned, id}` — after a `:suspend` cmd that ran
      `$EDITOR` returns. The reducer reloads the record list and
      re-selects `id` (which may be the just-created record).
  """

  alias Egghead.RecordStore
  alias Egghead.TUI.{Records.Model, ThemePicker}

  @preview_scroll_step 5

  @spec update(term(), Model.t()) :: {Model.t(), term()}

  # ---- runtime-synthesized messages ---------------------------------------

  def update({:resize, w, h}, model) do
    {Model.set_dimensions(model, w, h), :none}
  end

  def update({:editor_returned, id}, model) do
    {Model.reload(model, id), :none}
  end

  def update({:editor_failed, _reason}, model), do: {model, :none}

  # ---- record change events -----------------------------------------------

  def update({:record_event, {:record_changed, _id}}, model) do
    {Model.reload(model, model.selected_id), :none}
  end

  def update({:record_event, _}, model), do: {model, :none}

  # ---- theme change -------------------------------------------------------
  #
  # `preview_rendered` stores markdown rows with fg binaries baked
  # in — a theme switch leaves those stale. Drop the cached rows
  # and rebuild at the current width.

  def update({:theme_changed, _name}, model) do
    {Model.invalidate_preview(model), :none}
  end

  # ---- theme picker -------------------------------------------------------
  #
  # Highest-priority mode: when the picker is open, every key
  # routes through ThemePicker until it closes on Enter or Esc.

  def update(msg, %Model{theme_picker: picker} = model) when not is_nil(picker) do
    handle_theme_picker(msg, picker, model)
  end

  # ---- command mode -------------------------------------------------------
  #
  # When the user is in command mode, key handling is intercepted
  # at the top of the dispatcher and routed to a separate handler
  # because the same keys (Up, Down, Enter, Backspace, printable
  # chars) mean different things — they navigate the dropdown and
  # edit `command_input`, not the records list and filter.

  def update(msg, %Model{command_mode: true} = model) do
    handle_command_mode(msg, model)
  end

  # ---- key bindings -------------------------------------------------------

  def update({:key, :up}, model), do: {move_selection(model, -1), :none}
  def update({:key, :down}, model), do: {move_selection(model, +1), :none}

  def update({:key, :enter}, model), do: handle_enter(model)

  def update({:key, :tab}, model), do: {Model.link_next(model), :none}
  def update({:key, :shift_tab}, model), do: {Model.link_prev(model), :none}

  def update({:key, key}, model) when key in [:escape, :ctrl_g] do
    cond do
      Model.link_mode?(model) -> {Model.link_deselect(model), :none}
      Model.help_visible?(model) -> {Model.dismiss_help(model), :none}
      true -> {model, :none}
    end
  end

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
    if model.filter == "" and model.nav_history != [] do
      {Model.nav_back(model), :none}
    else
      {Model.delete_before_cursor(model), :none}
    end
  end

  def update({:char, "/"}, %Model{filter: ""} = model) do
    {Model.enter_command_mode(model), :none}
  end

  def update({:char, c}, model) when is_binary(c) do
    {Model.insert_at_cursor(model, c), :none}
  end

  # Readline-style cursor + kill commands within the search bar.
  def update({:key, :ctrl_a}, model), do: {Model.move_cursor_to_start(model), :none}
  def update({:key, :ctrl_e}, model), do: {Model.move_cursor_to_end(model), :none}
  def update({:key, :ctrl_k}, model), do: {Model.kill_to_eol(model), :none}
  def update({:key, :ctrl_u}, model), do: {Model.kill_to_bol(model), :none}
  def update({:key, :ctrl_w}, model), do: {Model.kill_word(model), :none}
  def update({:key, :left}, model), do: {Model.move_cursor_left(model), :none}
  def update({:key, :right}, model), do: {Model.move_cursor_right(model), :none}

  # Meta-key (Option-as-Meta) word movement and forward kill.
  def update({:key, :alt_b}, model), do: {Model.move_cursor_word_left(model), :none}
  def update({:key, :alt_f}, model), do: {Model.move_cursor_word_right(model), :none}
  def update({:key, :alt_d}, model), do: {Model.kill_word_forward(model), :none}
  def update({:key, :alt_backspace}, model), do: {Model.kill_word(model), :none}

  # Ctrl+L is the POSIX clear/redraw convention. Our renderer
  # already redraws every frame, so we just accept the keystroke
  # so it isn't surfaced as an unknown byte.
  def update({:key, :ctrl_l}, model), do: {model, :none}

  # Mouse wheel scrolls the preview pane. We don't bind clicks
  # yet — `:other` mouse events are silently swallowed so they
  # don't bubble up to the unknown-key fallback. Wheel uses a
  # smaller step (3 lines) than PgUp/PgDn (5 lines) since wheel
  # events arrive in a continuous stream.
  def update({:mouse, %{kind: :wheel_up, press?: true}}, model),
    do: {Model.scroll_preview(model, -3), :none}

  def update({:mouse, %{kind: :wheel_down, press?: true}}, model),
    do: {Model.scroll_preview(model, +3), :none}

  def update({:mouse, _}, model), do: {model, :none}

  def update(_other, model), do: {model, :none}

  # ---- enter dispatch -----------------------------------------------------

  defp handle_enter(model) do
    cond do
      Model.link_mode?(model) ->
        {Model.follow_active_link(model), :none}

      Model.phantom_selected?(model) ->
        case Model.creation_target(model) do
          {title, slug} -> {model, create_and_edit_cmd(slug, title)}
          nil -> {model, :none}
        end

      record = Enum.at(model.filtered, model.selection) ->
        case record.source_path do
          nil -> {model, :none}
          path -> {model, edit_existing_cmd(path, record.id)}
        end

      true ->
        {model, :none}
    end
  end

  # ---- command-mode dispatcher --------------------------------------------

  defp handle_command_mode({:key, key}, model) when key in [:escape, :ctrl_g],
    do: {Model.exit_command_mode(model), :none}

  defp handle_command_mode({:key, :enter}, model) do
    case Model.selected_command(model) do
      nil -> {Model.exit_command_mode(model), :none}
      cmd -> execute_command(cmd, model)
    end
  end

  defp handle_command_mode({:key, :up}, model),
    do: {Model.command_select(model, -1), :none}

  defp handle_command_mode({:key, :down}, model),
    do: {Model.command_select(model, +1), :none}

  defp handle_command_mode({:key, :backspace}, model),
    do: {Model.command_backspace(model), :none}

  defp handle_command_mode({:char, c}, model) when is_binary(c) do
    model = Model.command_input_char(model, c)

    # Autoload the theme picker the moment the user types
    # "theme " — same trigger shape as the @-mention dropdown
    # in chat. Subsequent keystrokes go to the picker as its
    # filter query.
    if String.downcase(model.command_input) == "theme " do
      {model |> Model.exit_command_mode() |> Model.open_theme_picker(), :none}
    else
      {model, :none}
    end
  end

  # Readline-style cursor + kill commands within the command
  # input. Same key bindings as the search bar — both delegate
  # to `Egghead.OpenTUI.Readline` under the hood.
  defp handle_command_mode({:key, :ctrl_a}, model),
    do: {Model.command_move_to_start(model), :none}

  defp handle_command_mode({:key, :ctrl_e}, model),
    do: {Model.command_move_to_end(model), :none}

  defp handle_command_mode({:key, :ctrl_k}, model),
    do: {Model.command_kill_to_eol(model), :none}

  defp handle_command_mode({:key, :ctrl_u}, model),
    do: {Model.command_kill_to_bol(model), :none}

  defp handle_command_mode({:key, :ctrl_w}, model),
    do: {Model.command_kill_word(model), :none}

  defp handle_command_mode({:key, :left}, model),
    do: {Model.command_move_left(model), :none}

  defp handle_command_mode({:key, :right}, model),
    do: {Model.command_move_right(model), :none}

  defp handle_command_mode({:key, :alt_b}, model),
    do: {Model.command_move_word_left(model), :none}

  defp handle_command_mode({:key, :alt_f}, model),
    do: {Model.command_move_word_right(model), :none}

  defp handle_command_mode({:key, :alt_d}, model),
    do: {Model.command_kill_word_forward(model), :none}

  defp handle_command_mode({:key, :alt_backspace}, model),
    do: {Model.command_kill_word(model), :none}

  # Mouse wheel still scrolls the preview while command mode is
  # active — convenient if /help opens a long help record.
  defp handle_command_mode({:mouse, %{kind: :wheel_up, press?: true}}, model),
    do: {Model.scroll_preview(model, -3), :none}

  defp handle_command_mode({:mouse, %{kind: :wheel_down, press?: true}}, model),
    do: {Model.scroll_preview(model, +3), :none}

  defp handle_command_mode(_other, model), do: {model, :none}

  # ---- command execution --------------------------------------------------

  defp execute_command(%{name: "quit"}, model) do
    {model, :halt}
  end

  defp execute_command(%{name: "help"}, model) do
    {Model.show_help(model) |> Model.exit_command_mode(), :none}
  end

  defp execute_command(%{name: "tools"}, model) do
    {Model.show_tools(model) |> Model.exit_command_mode(), :none}
  end

  defp execute_command(%{name: "mcp"}, model) do
    {Model.show_mcp(model) |> Model.exit_command_mode(), :none}
  end

  defp execute_command(%{name: "copy"}, model) do
    body = model.selected_body || ""
    Egghead.OpenTUI.Clipboard.copy(body)
    {Model.exit_command_mode(model), :none}
  end

  defp execute_command(%{name: "debug"}, model) do
    model = Model.exit_command_mode(model)
    {model, debug_dump_cmd(model)}
  end

  defp execute_command(%{name: "chat"}, model) do
    # Leave the records screen and let the App shell take over.
    # The shell intercepts `:switch_screen` and initialises the
    # chat screen lazily on first entry, passing the default
    # room id so the screen can subscribe to its PubSub topic
    # and hydrate the existing transcript. Later entries just
    # resume the existing chat model with its accumulated state.
    init_arg = [room_id: Egghead.default_room()]
    {Model.exit_command_mode(model), {:switch_screen, :chat, init_arg}}
  end

  defp execute_command(%{name: "join"}, model) do
    # Extract argument: everything after "join " in the command input
    arg =
      model.command_input
      |> String.trim()
      |> String.replace(~r/^join\s*/i, "")
      |> String.trim()

    room_id =
      case arg do
        "" -> Egghead.default_room()
        target -> resolve_join_target(target)
      end

    case room_id do
      nil ->
        {Model.exit_command_mode(model), :none}

      id ->
        {Model.exit_command_mode(model), {:switch_screen, :chat, [room_id: id]}}
    end
  end

  defp execute_command(%{name: "list"}, model) do
    {Model.show_rooms(model) |> Model.exit_command_mode(), :none}
  end

  defp execute_command(%{name: "system"}, model) do
    # Stub: system mode lands later.
    {Model.exit_command_mode(model), :none}
  end

  defp execute_command(%{name: "theme"}, model) do
    arg =
      model.command_input
      |> String.trim()
      |> String.replace(~r/^theme\s*/i, "")
      |> String.trim()

    model = Model.exit_command_mode(model)

    case arg do
      "" ->
        {Model.open_theme_picker(model), :none}

      name ->
        case ThemePicker.apply(name) do
          :ok -> {Model.invalidate_preview(model), :none}
          {:error, :not_found} -> {model, :none}
        end
    end
  end

  defp execute_command(_unknown, model) do
    {Model.exit_command_mode(model), :none}
  end

  # ---- theme picker routing ----------------------------------------------

  defp handle_theme_picker(msg, picker, model) do
    case ThemePicker.handle_key(msg, picker) do
      {_picker, status} when status in [:committed, :cancelled] ->
        # Picker has already installed the final palette (commit
        # → chosen theme; cancel → original theme) and
        # MarkdownCache is flushed. But `preview_rendered` has
        # fg binaries baked in from the last live-preview step,
        # so we invalidate it inline — the very next frame
        # repaints the preview in the now-active palette.
        {model |> Model.close_theme_picker() |> Model.invalidate_preview(), :none}

      {updated, :open} ->
        # Live preview: arrow keys switched the palette via
        # Theme.set/1 and reset the cache. Drop preview_rendered
        # so the next frame re-renders spans with fresh fg.
        {%{model | theme_picker: updated} |> Model.invalidate_preview(), :none}
    end
  end

  @valid_room_name ~r/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/

  defp resolve_join_target(target) do
    cond do
      Egghead.room_exists?(target) ->
        target

      true ->
        candidate = if String.starts_with?(target, "chat/"), do: target, else: "chat/#{target}"

        case Egghead.Chat.Room.from_transcript(candidate) do
          {:ok, room_id} ->
            room_id

          {:error, _} ->
            if String.length(target) <= 64 and Regex.match?(@valid_room_name, target) do
              case Egghead.create_room(id: target) do
                {:ok, room_id} -> room_id
                {:error, _} -> nil
              end
            else
              nil
            end
        end
    end
  end

  # `/debug` writes the current view tree to /tmp via an :exec
  # cmd. The closure captures `model` from execute_command's
  # scope, so the dump reflects the model state at the moment
  # the command was executed.
  defp debug_dump_cmd(model) do
    {:exec,
     fn ->
       path = "/tmp/egghead-render.log"
       tree = Egghead.TUI.Records.View.render(model)

       _ =
         File.write(
           path,
           inspect(tree, pretty: true, limit: :infinity, printable_limit: :infinity)
         )

       :no_msg
     end}
  end

  # ---- editor cmds --------------------------------------------------------

  defp edit_existing_cmd(path, id) do
    {:suspend,
     fn ->
       _ = spawn_editor(path)
       {:editor_returned, id}
     end}
  end

  defp create_and_edit_cmd(slug, title) do
    {:suspend,
     fn ->
       attrs =
         %{id: slug, class: :durable}
         |> maybe_put_title(slug, title)

       case RecordStore.create_record(attrs) do
         {:ok, record} ->
           _ = spawn_editor(record.source_path)
           {:editor_returned, record.id}

         {:error, reason} ->
           {:editor_failed, reason}
       end
     end}
  end

  defp maybe_put_title(attrs, slug, title) when slug == title, do: attrs
  defp maybe_put_title(attrs, _slug, title), do: Map.put(attrs, :title, title)

  # Spawn `$EDITOR` (or nano) on `path` via a shell port with
  # `:nouse_stdio` so the editor inherits the BEAM's controlling
  # tty directly. Mirrors the pattern in `Egghead.tui_loop/0` on
  # `main` (lib/egghead.ex). Blocks until the editor exits.
  defp spawn_editor(path) do
    sh = System.find_executable("sh") || "/bin/sh"
    editor = System.get_env("EDITOR") || System.get_env("VISUAL") || "nano"
    escaped = String.replace(path, "'", "'\\''")

    port =
      Port.open({:spawn_executable, sh}, [
        :nouse_stdio,
        :exit_status,
        args: ["-c", "#{editor} '#{escaped}'"]
      ])

    receive do
      {^port, {:exit_status, status}} -> status
    end
  end

  # ---- internals ----------------------------------------------------------

  defp move_selection(model, delta) do
    n = Model.list_total(model)

    new_sel =
      cond do
        n == 0 -> 0
        true -> model.selection |> Kernel.+(delta) |> max(0) |> min(n - 1)
      end

    %{model | selection: new_sel}
    |> Model.hydrate_selection()
  end
end
