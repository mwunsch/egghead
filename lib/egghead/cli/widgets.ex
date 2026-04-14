defmodule Egghead.CLI.Widgets do
  @moduledoc """
  Interactive CLI widgets powered by the OpenTUI Bridge NIF.

  Uses `Bridge.enter_raw_mode/0` for raw terminal access and
  `Input.read_one_key/1` for escape sequence parsing. Renders
  inline with ANSI escape codes — no alt screen, no renderer.

  Falls back to `Egghead.CLI.Prompts` when the NIF isn't available
  or stdin isn't a TTY.
  """

  alias Egghead.CLI.Prompts

  # In raw mode, \n does NOT imply \r. Every line must end with \r\n.
  defp raw_puts(text), do: IO.write([text, "\r\n"])

  # ── Select ──────────────────────────────────────────────────

  @doc """
  Arrow-key single selection. Type to filter.

  Options:
  - `:label` — prompt text above the list
  - `:render_as` — `fn item -> string` for display (default: `to_string`)
  """
  def select(items, opts \\ []) do
    label = Keyword.get(opts, :label)
    render_as = Keyword.get(opts, :render_as, &to_string/1)

    case items do
      [] ->
        nil

      [single] ->
        single

      _ ->
        if bridge?() do
          do_select(items, label, render_as)
        else
          Prompts.select(label || "Select:", items, label: render_as)
        end
    end
  end

  @doc """
  Arrow-key selection with group headers.

  `groups` is `[{group_label, [items]}]`. Group headers are
  displayed but not selectable — the cursor skips them.
  """
  def select_grouped(groups, opts \\ []) do
    label = Keyword.get(opts, :label)
    render_as = Keyword.get(opts, :render_as, &to_string/1)

    rows =
      Enum.flat_map(groups, fn {group_label, items} ->
        [{:group, group_label} | Enum.map(items, &{:item, &1})]
      end)

    selectable_indices =
      rows
      |> Enum.with_index()
      |> Enum.filter(fn {{type, _}, _} -> type == :item end)
      |> Enum.map(fn {_, idx} -> idx end)

    if selectable_indices == [] do
      nil
    else
      if bridge?() do
        do_select_grouped(rows, selectable_indices, label, render_as)
      else
        Prompts.select_grouped(label || "Select:", groups, label: render_as)
      end
    end
  end

  # ── Multiselect ─────────────────────────────────────────────

  @doc """
  Arrow-key + space checkbox selection.

  `items` is `[{label, value}]`.

  Options:
  - `:label` — prompt text
  - `:defaults` — list of pre-selected values
  """
  def multiselect(items, opts \\ []) do
    label = Keyword.get(opts, :label)
    defaults = Keyword.get(opts, :defaults, [])

    if bridge?() do
      do_multiselect(items, label, MapSet.new(defaults))
    else
      Prompts.checkboxes(label || "Select:", items, defaults: defaults)
    end
  end

  # ── Input ───────────────────────────────────────────────────

  @doc """
  Text input with optional default shown as placeholder.

  Options:
  - `:default` — value returned on empty Enter; shown in prompt
  """
  def input(label, opts \\ []) do
    default = Keyword.get(opts, :default)

    if bridge?() do
      do_input(label, default)
    else
      Prompts.prompt(label, default)
    end
  end

  # ── Secret ──────────────────────────────────────────────────

  @doc """
  Masked input with partial reveal.

  Shows first `:reveal_prefix` chars in cleartext, masks the rest.
  After confirmation, prints collapsed `prefix...suffix` summary.

  Options:
  - `:reveal_prefix` — leading chars to show (default: 7)
  - `:reveal_suffix` — trailing chars in summary (default: 4)
  """
  def secret(label, opts \\ []) do
    prefix_len = Keyword.get(opts, :reveal_prefix, 7)
    suffix_len = Keyword.get(opts, :reveal_suffix, 4)

    value =
      if bridge?() do
        do_secret(label, prefix_len)
      else
        Prompts.secret(label)
      end

    if value && value != "" do
      summary = mask_summary(value, prefix_len, suffix_len)
      IO.puts("  \e[90m#{summary}\e[0m")
    end

    value
  end

  # ── Spinner ─────────────────────────────────────────────────

  @frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  @doc "Show a spinner while running an async operation. Returns the callback result."
  def spinner(label, fun) do
    pid = spawn(fn -> spin_loop(label, 0) end)

    try do
      fun.()
    after
      Process.exit(pid, :kill)
      # Clear the spinner line completely
      IO.write("\r\e[2K")
    end
  end

  defp spin_loop(label, idx) do
    frame = Enum.at(@frames, rem(idx, length(@frames)))
    IO.write("\r\e[2K\e[36m#{frame}\e[0m #{label}")
    Process.sleep(80)
    spin_loop(label, idx + 1)
  end

  # ── Confirm ─────────────────────────────────────────────────

  @doc "Yes/no confirmation. No raw mode needed."
  def confirm(message, opts \\ []) do
    default = Keyword.get(opts, :default, false)
    hint = if default, do: "[Y/n]", else: "[y/N]"

    case IO.gets("#{message} #{hint}: ") do
      :eof ->
        default

      result ->
        case String.trim(result) |> String.downcase() do
          "" -> default
          "y" -> true
          "yes" -> true
          "n" -> false
          "no" -> false
          _ -> confirm(message, opts)
        end
    end
  end

  # ── App start (quiet) ───────────────────────────────────────

  @doc """
  Start the OTP application without the web server and with the
  logger silenced. Use this in CLI commands that need the app
  running but don't want log spam in the terminal.
  """
  def start_app do
    Egghead.CLI.start_app(:silent, web: false)
  end

  # ── Styled output (outside raw mode, IO.puts is fine) ──────

  def success(msg), do: IO.puts("\e[32m✓\e[0m #{msg}")
  def error(msg), do: IO.puts("\e[31m✗\e[0m #{msg}")
  def warn(msg), do: IO.puts("\e[33m!\e[0m #{msg}")
  def header(msg), do: IO.puts("\n\e[1m#{msg}\e[0m")

  def format_context(nil), do: ""
  def format_context(n) when n >= 1_000_000, do: "#{div(n, 1_000_000)}M ctx"
  def format_context(n) when n >= 1_000, do: "#{div(n, 1_000)}K ctx"
  def format_context(n), do: "#{n} ctx"

  def pad(str, width) do
    len = String.length(str)
    if len >= width, do: str, else: str <> String.duplicate(" ", width - len)
  end

  # ── Masking helpers ─────────────────────────────────────────

  @doc false
  def mask_display(value, prefix_len) do
    len = String.length(value)

    cond do
      len == 0 -> ""
      len <= prefix_len -> value
      true -> String.slice(value, 0, prefix_len) <> String.duplicate("•", len - prefix_len)
    end
  end

  @doc false
  def mask_summary(value, prefix_len, suffix_len) do
    len = String.length(value)

    cond do
      len == 0 ->
        ""

      len <= prefix_len + suffix_len ->
        String.duplicate("•", len)

      true ->
        prefix = String.slice(value, 0, prefix_len)
        suffix = String.slice(value, -suffix_len, suffix_len)
        "#{prefix}...#{suffix}"
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Private: Bridge-powered widget implementations
  # ══════════════════════════════════════════════════════════════

  defp bridge? do
    Code.ensure_loaded?(Egghead.OpenTUI.Bridge) and
      function_exported?(Egghead.OpenTUI.Bridge, :enter_raw_mode, 0) and
      interactive?()
  end

  defp interactive? do
    # Check if there's a real terminal attached.
    # The NIF reads from /dev/tty directly, so piped stdin doesn't help —
    # we need an actual terminal the user can type into.
    case System.get_env("TERM") do
      nil ->
        false

      _ ->
        Code.ensure_loaded?(Egghead.OpenTUI.Bridge) and
          match?({:ok, _}, Egghead.OpenTUI.Bridge.tty_size())
    end
  rescue
    _ -> false
  end

  defp with_raw_mode(fun) do
    alias Egghead.OpenTUI.Bridge
    Bridge.enter_raw_mode()
    IO.write("\e[?25l")

    try do
      fun.()
    after
      IO.write("\e[?25h")
      Bridge.leave_raw_mode()
    end
  end

  defp read_key do
    Egghead.OpenTUI.Input.read_one_key()
  end

  # ── Select implementation ───────────────────────────────────

  defp do_select(items, label, render_as) do
    with_raw_mode(fn ->
      if label, do: raw_puts(label)
      select_loop(items, items, render_as, 0, "", label != nil)
    end)
  end

  defp select_loop(all_items, visible, render_as, cursor, filter, has_label) do
    lines = render_select(visible, render_as, cursor, filter, length(all_items))

    case read_key() do
      {:key, :up} ->
        new_cursor = max(0, cursor - 1)
        clear_lines(lines)
        select_loop(all_items, visible, render_as, new_cursor, filter, has_label)

      {:key, :down} ->
        new_cursor = min(length(visible) - 1, cursor + 1)
        clear_lines(lines)
        select_loop(all_items, visible, render_as, new_cursor, filter, has_label)

      {:key, :enter} ->
        clear_lines(lines)
        if has_label, do: clear_lines(1)
        selected = Enum.at(visible, cursor)
        if selected, do: raw_puts("\e[32m✓\e[0m #{render_as.(selected)}")
        selected

      {:key, :escape} ->
        clear_lines(lines)
        if has_label, do: clear_lines(1)
        nil

      {:key, :ctrl_c} ->
        clear_lines(lines)
        if has_label, do: clear_lines(1)
        nil

      {:key, :backspace} ->
        new_filter = String.slice(filter, 0..-2//1)
        new_visible = filter_items(all_items, render_as, new_filter)
        clear_lines(lines)
        select_loop(all_items, new_visible, render_as, 0, new_filter, has_label)

      {:char, c} ->
        new_filter = filter <> c
        new_visible = filter_items(all_items, render_as, new_filter)
        clear_lines(lines)
        select_loop(all_items, new_visible, render_as, 0, new_filter, has_label)

      _ ->
        select_loop(all_items, visible, render_as, cursor, filter, has_label)
    end
  end

  defp render_select(visible, render_as, cursor, filter, total) do
    filter_line =
      if filter != "" do
        raw_puts("  \e[90mfilter:\e[0m #{filter}")
        1
      else
        0
      end

    item_lines =
      if visible == [] do
        raw_puts("  \e[90m(no matches)\e[0m")
        1
      else
        visible
        |> Enum.with_index()
        |> Enum.each(fn {item, idx} ->
          indicator = if idx == cursor, do: "\e[36m▸\e[0m", else: " "
          text = render_as.(item)
          highlight = if idx == cursor, do: "\e[1m", else: ""
          raw_puts("  #{indicator} #{highlight}#{text}\e[0m")
        end)

        length(visible)
      end

    match_info =
      if filter != "" do
        "#{length(visible)} of #{total} matching · "
      else
        ""
      end

    raw_puts("  \e[90m#{match_info}↑/↓ navigate  enter select  esc cancel\e[0m")

    filter_line + item_lines + 1
  end

  defp filter_items(all, _render_as, ""), do: all

  defp filter_items(all, render_as, filter) do
    downcased = String.downcase(filter)

    Enum.filter(all, fn item ->
      render_as.(item) |> to_string() |> String.downcase() |> String.contains?(downcased)
    end)
  end

  # ── Grouped select implementation ──────────────────────────

  defp do_select_grouped(rows, selectable_indices, label, render_as) do
    with_raw_mode(fn ->
      if label, do: raw_puts(label)
      select_grouped_loop(rows, selectable_indices, render_as, 0, label != nil)
    end)
  end

  defp select_grouped_loop(rows, selectable_indices, render_as, cursor_pos, has_label) do
    current_idx = Enum.at(selectable_indices, cursor_pos)
    lines = render_grouped(rows, current_idx, render_as)

    case read_key() do
      {:key, :up} ->
        new_pos = max(0, cursor_pos - 1)
        clear_lines(lines)
        select_grouped_loop(rows, selectable_indices, render_as, new_pos, has_label)

      {:key, :down} ->
        new_pos = min(length(selectable_indices) - 1, cursor_pos + 1)
        clear_lines(lines)
        select_grouped_loop(rows, selectable_indices, render_as, new_pos, has_label)

      {:key, :enter} ->
        clear_lines(lines)
        if has_label, do: clear_lines(1)
        {:item, selected} = Enum.at(rows, current_idx)
        raw_puts("\e[32m✓\e[0m #{render_as.(selected)}")
        selected

      {:key, :escape} ->
        clear_lines(lines)
        if has_label, do: clear_lines(1)
        nil

      {:key, :ctrl_c} ->
        clear_lines(lines)
        if has_label, do: clear_lines(1)
        nil

      _ ->
        select_grouped_loop(rows, selectable_indices, render_as, cursor_pos, has_label)
    end
  end

  defp render_grouped(rows, current_idx, render_as) do
    rows
    |> Enum.with_index()
    |> Enum.each(fn
      {{:group, group_label}, _idx} ->
        raw_puts("  \e[1m#{group_label}\e[0m")

      {{:item, item}, idx} ->
        indicator = if idx == current_idx, do: "\e[36m▸\e[0m", else: " "
        highlight = if idx == current_idx, do: "\e[1m", else: ""
        raw_puts("    #{indicator} #{highlight}#{render_as.(item)}\e[0m")
    end)

    raw_puts("  \e[90m↑/↓ navigate  enter select  esc cancel\e[0m")
    length(rows) + 1
  end

  # ── Multiselect implementation ─────────────────────────────

  defp do_multiselect(items, label, selected) do
    with_raw_mode(fn ->
      if label, do: raw_puts(label)
      multiselect_loop(items, 0, selected, label != nil)
    end)
  end

  defp multiselect_loop(items, cursor, selected, has_label) do
    lines = render_multiselect(items, cursor, selected)

    case read_key() do
      {:key, :up} ->
        clear_lines(lines)
        multiselect_loop(items, max(0, cursor - 1), selected, has_label)

      {:key, :down} ->
        clear_lines(lines)
        multiselect_loop(items, min(length(items) - 1, cursor + 1), selected, has_label)

      {:key, :space} ->
        {_label, value} = Enum.at(items, cursor)

        new_selected =
          if MapSet.member?(selected, value),
            do: MapSet.delete(selected, value),
            else: MapSet.put(selected, value)

        clear_lines(lines)
        multiselect_loop(items, cursor, new_selected, has_label)

      {:key, :enter} ->
        clear_lines(lines)
        if has_label, do: clear_lines(1)

        result =
          items
          |> Enum.filter(fn {_label, value} -> MapSet.member?(selected, value) end)
          |> Enum.map(fn {_label, value} -> value end)

        raw_puts("\e[32m✓\e[0m #{length(result)} selected")
        result

      {:key, :escape} ->
        clear_lines(lines)
        if has_label, do: clear_lines(1)
        []

      {:key, :ctrl_c} ->
        clear_lines(lines)
        if has_label, do: clear_lines(1)
        []

      _ ->
        multiselect_loop(items, cursor, selected, has_label)
    end
  end

  defp render_multiselect(items, cursor, selected) do
    items
    |> Enum.with_index()
    |> Enum.each(fn {{label, value}, idx} ->
      indicator = if idx == cursor, do: "\e[36m▸\e[0m", else: " "
      check = if MapSet.member?(selected, value), do: "\e[32m✓\e[0m", else: " "
      highlight = if idx == cursor, do: "\e[1m", else: ""
      raw_puts("  #{indicator} [#{check}] #{highlight}#{label}\e[0m")
    end)

    raw_puts("  \e[90m↑/↓ navigate  space toggle  enter confirm\e[0m")
    length(items) + 1
  end

  # ── Input implementation ───────────────────────────────────

  defp do_input(label, default) do
    with_raw_mode(fn ->
      IO.write("#{label}\r\n")
      redraw_input("", 0, default)
      input_loop("", 0, default)
    end)
  end

  defp input_loop(text, cursor, default) do
    case read_key() do
      {:key, :enter} ->
        # Clear ghost text line, print final value
        IO.write("\r\n")
        if text == "", do: default || "", else: text

      {:key, :tab} ->
        # Tab fills in the ghost text
        if text == "" and default do
          new_text = default
          new_cursor = String.length(new_text)
          redraw_input(new_text, new_cursor, default)
          input_loop(new_text, new_cursor, default)
        else
          input_loop(text, cursor, default)
        end

      {:key, :backspace} ->
        {new_text, new_cursor} = Egghead.OpenTUI.Readline.delete_before(text, cursor)
        redraw_input(new_text, new_cursor, default)
        input_loop(new_text, new_cursor, default)

      {:key, :left} ->
        {new_text, new_cursor} = Egghead.OpenTUI.Readline.move_left(text, cursor)
        redraw_input(new_text, new_cursor, default)
        input_loop(new_text, new_cursor, default)

      {:key, :right} ->
        {new_text, new_cursor} = Egghead.OpenTUI.Readline.move_right(text, cursor)
        redraw_input(new_text, new_cursor, default)
        input_loop(new_text, new_cursor, default)

      {:key, :ctrl_a} ->
        {new_text, new_cursor} = Egghead.OpenTUI.Readline.move_to_start(text, cursor)
        redraw_input(new_text, new_cursor, default)
        input_loop(new_text, new_cursor, default)

      {:key, :ctrl_e} ->
        {new_text, new_cursor} = Egghead.OpenTUI.Readline.move_to_end(text, cursor)
        redraw_input(new_text, new_cursor, default)
        input_loop(new_text, new_cursor, default)

      {:key, :ctrl_u} ->
        redraw_input("", 0, default)
        input_loop("", 0, default)

      {:key, :ctrl_w} ->
        {new_text, new_cursor} = Egghead.OpenTUI.Readline.kill_word(text, cursor)
        redraw_input(new_text, new_cursor, default)
        input_loop(new_text, new_cursor, default)

      {:key, :ctrl_c} ->
        IO.write("\r\n")
        nil

      {:key, :escape} ->
        IO.write("\r\n")
        nil

      {:char, c} ->
        {new_text, new_cursor} = Egghead.OpenTUI.Readline.insert(text, cursor, c)
        redraw_input(new_text, new_cursor, default)
        input_loop(new_text, new_cursor, default)

      {:paste, pasted} ->
        {new_text, new_cursor} = Egghead.OpenTUI.Readline.insert(text, cursor, pasted)
        redraw_input(new_text, new_cursor, default)
        input_loop(new_text, new_cursor, default)

      _ ->
        input_loop(text, cursor, default)
    end
  end

  defp redraw_input(text, cursor, default) do
    IO.write("\r\e[2K  \e[34m>\e[0m ")

    if text == "" and default do
      # Ghost text — dim gray, cursor stays at prompt position
      IO.write("\e[90m#{default}\e[0m")
      # Move cursor back to just after "> "
      ghost_len = String.length(default)
      IO.write("\e[#{ghost_len}D")
    else
      IO.write(text)
      chars_after = String.length(text) - cursor
      if chars_after > 0, do: IO.write("\e[#{chars_after}D")
    end
  end

  # ── Secret implementation ──────────────────────────────────

  defp do_secret(label, prefix_len) do
    with_raw_mode(fn ->
      IO.write("#{label}: ")
      secret_loop("", 0, prefix_len, label)
    end)
  end

  defp secret_loop(text, cursor, prefix_len, label) do
    alias Egghead.OpenTUI.Readline

    case read_key() do
      {:key, :enter} ->
        IO.write("\r\n")
        text

      {:key, :backspace} ->
        {new_text, new_cursor} = Readline.delete_before(text, cursor)
        redraw_secret(new_text, prefix_len, label)
        secret_loop(new_text, new_cursor, prefix_len, label)

      {:key, :left} ->
        {_, new_cursor} = Readline.move_left(text, cursor)
        secret_loop(text, new_cursor, prefix_len, label)

      {:key, :right} ->
        {_, new_cursor} = Readline.move_right(text, cursor)
        secret_loop(text, new_cursor, prefix_len, label)

      {:key, :ctrl_a} ->
        {_, new_cursor} = Readline.move_to_start(text, cursor)
        secret_loop(text, new_cursor, prefix_len, label)

      {:key, :ctrl_e} ->
        {_, new_cursor} = Readline.move_to_end(text, cursor)
        secret_loop(text, new_cursor, prefix_len, label)

      {:key, :ctrl_k} ->
        {new_text, new_cursor} = Readline.kill_to_eol(text, cursor)
        redraw_secret(new_text, prefix_len, label)
        secret_loop(new_text, new_cursor, prefix_len, label)

      {:key, :ctrl_u} ->
        {new_text, new_cursor} = Readline.kill_to_bol(text, cursor)
        redraw_secret(new_text, prefix_len, label)
        secret_loop(new_text, new_cursor, prefix_len, label)

      {:key, :ctrl_w} ->
        {new_text, new_cursor} = Readline.kill_word(text, cursor)
        redraw_secret(new_text, prefix_len, label)
        secret_loop(new_text, new_cursor, prefix_len, label)

      {:key, :ctrl_c} ->
        IO.write("\r\n")
        nil

      {:key, :escape} ->
        IO.write("\r\n")
        nil

      {:char, c} ->
        {new_text, new_cursor} = Readline.insert(text, cursor, c)
        redraw_secret(new_text, prefix_len, label)
        secret_loop(new_text, new_cursor, prefix_len, label)

      {:paste, pasted} ->
        {new_text, new_cursor} = Readline.insert(text, cursor, pasted)
        redraw_secret(new_text, prefix_len, label)
        secret_loop(new_text, new_cursor, prefix_len, label)

      _ ->
        secret_loop(text, cursor, prefix_len, label)
    end
  end

  defp redraw_secret(text, prefix_len, label) do
    display = mask_display(text, prefix_len)
    IO.write("\r\e[2K#{label}: #{display}")
  end

  # ── ANSI helpers ───────────────────────────────────────────

  defp clear_lines(0), do: :ok

  defp clear_lines(n) do
    for _ <- 1..n do
      IO.write("\e[1A\r\e[2K")
    end
  end
end
