defmodule Egghead.OpenTUI.Input do
  @moduledoc """
  Raw-mode key reader.

  All bytes flow through `Egghead.OpenTUI.Bridge.read_key/1`,
  which reads a single byte from `/dev/tty` via a dedicated
  O_NONBLOCK fd inside the NIF. We use exactly one input fd
  process-wide to avoid racing the line discipline.

  Decodes printable ASCII, the common Ctrl+letter control bytes,
  backspace (DEL, 0x7F), the four CSI arrow keys, the CSI
  Page Up / Page Down sequences, SGR mouse events, the Kitty
  keyboard protocol's `CSI <code>;<mods> u` form (for chords
  like Shift+Enter), and bracketed paste payloads.

  Returns one of:
    * `{:char, "x"}` — a printable ASCII byte (0x20–0x7E)
    * `{:key, :escape}` — bare ESC (disambiguated by ~50ms timeout)
    * `{:key, :ctrl_a | :ctrl_c | :ctrl_e | :ctrl_f | :ctrl_k | :ctrl_l |
            :ctrl_n | :ctrl_p | :ctrl_q | :ctrl_t | :ctrl_u | :ctrl_w |
            :ctrl_z}`
    * `{:key, :alt_b | :alt_d | :alt_f | :alt_backspace}` — common
      Meta-key (Option-as-Meta) sequences for readline-style word
      movement and kill
    * `{:key, :backspace}` — DEL (0x7F)
    * `{:key, :tab}` — TAB (0x09)
    * `{:key, :shift_tab}` — Shift+TAB (CSI Z, a.k.a. CBT / cursor back tab)
    * `{:key, :enter}` — CR (0x0D) / LF (0x0A)
    * `{:key, :shift_enter | :alt_enter | :ctrl_enter}` — Kitty
      keyboard protocol disambiguated Enter chords
    * `{:key, :up | :down | :left | :right}` — CSI arrows
    * `{:key, :page_up | :page_down}` — CSI 5~ / 6~
    * `{:mouse, %{kind: :wheel_up | :wheel_down | :other,
                  press?: boolean(), col: integer(), row: integer()}}`
      — SGR mouse event (mode ?1006). Wheel events arrive as
      kind `:wheel_up` (button 64) / `:wheel_down` (button 65);
      everything else (clicks, drags, motion) is `:other`.
    * `{:paste, text}` — bracketed paste payload (everything between
      `CSI 200~` and `CSI 201~`, with control characters other than
      `\\n` and `\\t` stripped)
    * `{:key, {:byte, n}}` — an unrecognized control byte
    * `{:key, :unknown}` — an unrecognized escape sequence
    * `{:key, :eof}` — the tty closed

  ## Bare ESC disambiguation

  After reading `0x1B`, we peek for one more byte with a 50ms
  timeout (the standard xterm-style disambiguation window). If a
  byte arrives, it's the start of an escape sequence (`[` for
  CSI, `b`/`d`/`f` for Alt-letter, etc.). If 50ms passes with
  nothing, the user pressed bare ESC.

  ## Test seam

  `parse/1` takes an explicit byte-source function so the parser
  can be unit tested without going through the NIF. The
  production entry point `read_one_key/0` supplies
  `&Bridge.read_key/1`.
  """

  alias Egghead.OpenTUI.Bridge

  # 50ms is the standard ESC-vs-sequence disambiguation window.
  # Long enough to capture even slow-arriving CSI bytes from a
  # remote tty, short enough that bare ESC feels responsive.
  @esc_timeout_ms 50

  # Cap a paste payload at 1 MiB. Anything longer is almost
  # certainly a stuck terminal or a malicious peer; bail out
  # rather than building an unbounded binary.
  @paste_max_bytes 1_048_576

  @typedoc """
  A function that reads one byte from the underlying byte source.
  Mirrors the shape of `Egghead.OpenTUI.Bridge.read_key/1`:

    * `{:ok, byte()}`
    * `:timeout`
    * `:eof`
  """
  @type reader ::
          (non_neg_integer() ->
             {:ok, byte()} | :timeout | :eof)

  @doc """
  Block until one key is read from `/dev/tty`. Returns a parsed
  key tuple. Safe to call from any process — the underlying NIF
  is dirty I/O bound and parks on a dirty scheduler thread while
  blocked.
  """
  def read_one_key, do: parse(&Bridge.read_key/1)

  @doc """
  Parse one event using the supplied byte-source function.
  Used directly by tests; the production reader is
  `read_one_key/0`.
  """
  @spec parse(reader()) :: term()
  def parse(reader) when is_function(reader, 1) do
    parse_next(reader)
  end

  defp parse_next(reader) do
    case reader.(0) do
      {:ok, 0x01} -> {:key, :ctrl_a}
      {:ok, 0x03} -> {:key, :ctrl_c}
      {:ok, 0x05} -> {:key, :ctrl_e}
      {:ok, 0x06} -> {:key, :ctrl_f}
      {:ok, 0x09} -> {:key, :tab}
      {:ok, 0x0A} -> {:key, :enter}
      {:ok, 0x0B} -> {:key, :ctrl_k}
      {:ok, 0x0C} -> {:key, :ctrl_l}
      {:ok, 0x0D} -> {:key, :enter}
      {:ok, 0x0E} -> {:key, :ctrl_n}
      {:ok, 0x10} -> {:key, :ctrl_p}
      {:ok, 0x11} -> {:key, :ctrl_q}
      {:ok, 0x14} -> {:key, :ctrl_t}
      {:ok, 0x15} -> {:key, :ctrl_u}
      {:ok, 0x17} -> {:key, :ctrl_w}
      {:ok, 0x1A} -> {:key, :ctrl_z}
      {:ok, 0x1B} -> parse_escape(reader)
      {:ok, 0x7F} -> {:key, :backspace}
      {:ok, byte} when byte >= 0x20 and byte < 0x7F -> {:char, <<byte>>}
      {:ok, byte} -> {:key, {:byte, byte}}
      :timeout -> {:key, :eof}
      :eof -> {:key, :eof}
    end
  end

  # After 0x1B: peek with a short timeout. No byte → bare ESC.
  defp parse_escape(reader) do
    case reader.(@esc_timeout_ms) do
      :timeout -> {:key, :escape}
      :eof -> {:key, :escape}
      {:ok, ?[} -> parse_csi(reader)
      {:ok, ?b} -> {:key, :alt_b}
      {:ok, ?d} -> {:key, :alt_d}
      {:ok, ?f} -> {:key, :alt_f}
      {:ok, 0x0D} -> {:key, :alt_enter}
      {:ok, 0x0A} -> {:key, :alt_enter}
      {:ok, 0x7F} -> {:key, :alt_backspace}
      {:ok, _} -> {:key, :escape}
    end
  end

  # Generic CSI parser. The SGR mouse form starts with `<` (a
  # private-use prefix), so it branches off before parameter
  # collection. Everything else collects digit/`;` parameters
  # until a final byte in 0x40..0x7E.
  defp parse_csi(reader) do
    case reader.(@esc_timeout_ms) do
      {:ok, ?<} -> parse_sgr_mouse(reader)
      {:ok, b} -> read_csi_params(reader, [b], 1)
      _ -> {:key, :unknown}
    end
  end

  # Cap params at 32 bytes — real CSI sequences fit in well
  # under that. Anything longer is garbled; bail to :unknown.
  defp read_csi_params(_reader, _acc, count) when count >= 32, do: {:key, :unknown}

  defp read_csi_params(reader, [last | _] = acc, count) do
    cond do
      last >= 0x40 and last <= 0x7E ->
        # The most recently appended byte is the final byte.
        params = acc |> tl() |> Enum.reverse() |> List.to_string()
        dispatch_csi(params, last, reader)

      true ->
        case reader.(@esc_timeout_ms) do
          {:ok, b} -> read_csi_params(reader, [b | acc], count + 1)
          _ -> {:key, :unknown}
        end
    end
  end

  defp dispatch_csi("", ?A, _), do: {:key, :up}
  defp dispatch_csi("", ?B, _), do: {:key, :down}
  defp dispatch_csi("", ?C, _), do: {:key, :right}
  defp dispatch_csi("", ?D, _), do: {:key, :left}
  defp dispatch_csi("", ?Z, _), do: {:key, :shift_tab}
  defp dispatch_csi("5", ?~, _), do: {:key, :page_up}
  defp dispatch_csi("6", ?~, _), do: {:key, :page_down}
  defp dispatch_csi("200", ?~, reader), do: read_paste(reader, [], 0)
  defp dispatch_csi(params, ?u, _), do: decode_kitty_u(params)
  defp dispatch_csi(_, _, _), do: {:key, :unknown}

  # Kitty `CSI <code>;<mods> u` (or `CSI <code> u`).
  #
  # `<code>` is the unicode codepoint of the unmodified key.
  # `<mods>` is `1 + bitmask`, where the bitmask is
  # `1=shift  2=alt  4=ctrl  8=super  …`. Bare ESC mods means no
  # modifier (encoded as `1`, omitted, or simply absent).
  #
  # We currently only special-case Enter (13), Tab (9), and ESC
  # (27); other codes fall back to plain `:enter`/`:tab`/`:escape`
  # for their bare forms or `:unknown`. The set of recognised
  # chords can grow as call sites need them.
  defp decode_kitty_u(params) do
    case String.split(params, ";", parts: 2) do
      [code_str] ->
        case Integer.parse(code_str) do
          {code, ""} -> kitty_key(code, 0)
          _ -> {:key, :unknown}
        end

      [code_str, rest] ->
        # Mods may itself contain a sub-event subfield (`mods:event`);
        # we only care about the leading mods integer.
        mods_str = rest |> String.split(":", parts: 2) |> hd()

        with {code, ""} <- Integer.parse(code_str),
             {mods_plus_one, ""} <- Integer.parse(mods_str) do
          kitty_key(code, max(mods_plus_one - 1, 0))
        else
          _ -> {:key, :unknown}
        end
    end
  end

  # mods bitmask: 1=shift, 2=alt, 4=ctrl
  defp kitty_key(13, 0), do: {:key, :enter}

  defp kitty_key(13, mods) do
    cond do
      Bitwise.band(mods, 2) != 0 -> {:key, :alt_enter}
      Bitwise.band(mods, 1) != 0 -> {:key, :shift_enter}
      Bitwise.band(mods, 4) != 0 -> {:key, :ctrl_enter}
      true -> {:key, :enter}
    end
  end

  defp kitty_key(9, 0), do: {:key, :tab}
  defp kitty_key(9, 1), do: {:key, :shift_tab}
  defp kitty_key(27, _), do: {:key, :escape}
  defp kitty_key(_code, _mods), do: {:key, :unknown}

  # Bracketed paste body. Read bytes until we see the literal
  # sequence `\e[201~`. ESC inside the payload is rare in
  # practice; if we see one, peek the next 5 bytes and treat
  # them as either the terminator or as paste content.
  defp read_paste(_reader, acc, count) when count >= @paste_max_bytes do
    {:paste, finalize_paste(acc)}
  end

  defp read_paste(reader, acc, count) do
    case reader.(0) do
      {:ok, 0x1B} ->
        case read_n(reader, 5) do
          [?[, ?2, ?0, ?1, ?~] ->
            {:paste, finalize_paste(acc)}

          bytes ->
            new_acc = Enum.reduce(bytes, [0x1B | acc], fn b, a -> [b | a] end)
            read_paste(reader, new_acc, count + 1 + length(bytes))
        end

      {:ok, b} ->
        read_paste(reader, [b | acc], count + 1)

      _ ->
        {:paste, finalize_paste(acc)}
    end
  end

  defp read_n(_reader, 0), do: []

  defp read_n(reader, n) do
    case reader.(@esc_timeout_ms) do
      {:ok, b} -> [b | read_n(reader, n - 1)]
      _ -> []
    end
  end

  # Strip control characters except `\n` and `\t`. The terminal
  # may inject odd bytes if it's mid-state when paste begins;
  # we want a clean text payload to hand the screen.
  defp finalize_paste(reversed) do
    reversed
    |> Enum.reverse()
    |> Enum.filter(fn b -> b == ?\n or b == ?\t or (b >= 0x20 and b != 0x7F) end)
    |> List.to_string()
  end

  # SGR mouse encoding (xterm mode ?1006):
  #
  #     ESC [ < button ; col ; row M    (press / wheel)
  #     ESC [ < button ; col ; row m    (release)
  #
  # Buttons:
  #   0 / 1 / 2  — left / middle / right
  #   + 4         shift held
  #   + 8         meta held
  #   + 16        ctrl held
  #   + 32        motion (button held while moving)
  #   64          wheel up
  #   65          wheel down
  #   66          wheel left
  #   67          wheel right
  #
  # We collect bytes until M or m, then decode. We only
  # special-case wheel-up / wheel-down (the most common case for
  # a TUI); everything else surfaces as `:other` so the screen
  # can ignore or extend later.
  defp parse_sgr_mouse(reader), do: read_mouse_params(reader, [], 0)

  # Cap the parameter buffer at 64 bytes — a real SGR mouse
  # sequence is at most ~16 bytes. Anything past the cap is a
  # garbled sequence; bail to :unknown so we don't loop forever.
  defp read_mouse_params(_reader, _acc, count) when count >= 64, do: {:key, :unknown}

  defp read_mouse_params(reader, acc, count) do
    case reader.(@esc_timeout_ms) do
      {:ok, ?M} -> finalize_mouse(acc, true)
      {:ok, ?m} -> finalize_mouse(acc, false)
      {:ok, byte} -> read_mouse_params(reader, [byte | acc], count + 1)
      _ -> {:key, :unknown}
    end
  end

  defp finalize_mouse(reversed_bytes, press?) do
    params =
      reversed_bytes
      |> Enum.reverse()
      |> List.to_string()
      |> String.split(";")
      |> Enum.map(&parse_int/1)

    case params do
      [button, col, row] when is_integer(button) and is_integer(col) and is_integer(row) ->
        kind = decode_mouse_button(button)
        {:mouse, %{kind: kind, press?: press?, col: col, row: row}}

      _ ->
        {:key, :unknown}
    end
  end

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  # Mask off the modifier bits (shift/meta/ctrl/motion) so
  # 64+motion still decodes to wheel_up. Modifier and motion
  # state isn't surfaced yet — easy to add later.
  defp decode_mouse_button(button) do
    base = Bitwise.band(button, Bitwise.bnot(32))

    case base do
      64 -> :wheel_up
      65 -> :wheel_down
      _ -> :other
    end
  end
end
