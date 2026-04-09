defmodule Egghead.OpenTUI.Input do
  @moduledoc """
  Raw-mode key reader.

  All bytes flow through `Egghead.OpenTUI.Bridge.read_key/1`,
  which reads a single byte from `/dev/tty` via a dedicated
  O_NONBLOCK fd inside the NIF. We use exactly one input fd
  process-wide to avoid racing the line discipline.

  Decodes printable ASCII, the common Ctrl+letter control bytes,
  backspace (DEL, 0x7F), the four CSI arrow keys, the CSI
  Page Up / Page Down sequences, and a handful of Meta-key
  (Option-as-Meta) sequences. A fuller input reader (Kitty
  keyboard protocol, bracketed paste, mouse, focus events) is
  not yet implemented.

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
    * `{:key, :up | :down | :left | :right}` — CSI arrows
    * `{:key, :page_up | :page_down}` — CSI 5~ / 6~
    * `{:key, {:byte, n}}` — an unrecognized control byte
    * `{:key, :unknown}` — an unrecognized escape sequence
    * `{:key, :eof}` — the tty closed

  ## Bare ESC disambiguation

  After reading `0x1B`, we peek for one more byte with a 50ms
  timeout (the standard xterm-style disambiguation window). If a
  byte arrives, it's the start of an escape sequence (`[` for
  CSI, `b`/`d`/`f` for Alt-letter, etc.). If 50ms passes with
  nothing, the user pressed bare ESC.
  """

  alias Egghead.OpenTUI.Bridge

  # 50ms is the standard ESC-vs-sequence disambiguation window.
  # Long enough to capture even slow-arriving CSI bytes from a
  # remote tty, short enough that bare ESC feels responsive.
  @esc_timeout_ms 50

  @doc """
  Block until one key is read from `/dev/tty`. Returns a parsed
  key tuple. Safe to call from any process — the underlying NIF
  is dirty I/O bound and parks on a dirty scheduler thread while
  blocked.
  """
  def read_one_key do
    parse_next()
  end

  defp parse_next do
    case Bridge.read_key(0) do
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
      {:ok, 0x1B} -> parse_escape()
      {:ok, 0x7F} -> {:key, :backspace}
      {:ok, byte} when byte >= 0x20 and byte < 0x7F -> {:char, <<byte>>}
      {:ok, byte} -> {:key, {:byte, byte}}
      :timeout -> {:key, :eof}
      :eof -> {:key, :eof}
    end
  end

  # After 0x1B: peek with a short timeout. No byte → bare ESC.
  defp parse_escape do
    case Bridge.read_key(@esc_timeout_ms) do
      :timeout -> {:key, :escape}
      :eof -> {:key, :escape}
      {:ok, ?[} -> parse_csi()
      {:ok, ?b} -> {:key, :alt_b}
      {:ok, ?d} -> {:key, :alt_d}
      {:ok, ?f} -> {:key, :alt_f}
      {:ok, 0x7F} -> {:key, :alt_backspace}
      {:ok, _} -> {:key, :escape}
    end
  end

  # CSI sequences after `ESC [`. Single-letter arrow forms
  # (`A`/`B`/`C`/`D`) and the digit-prefixed `5~` (Page Up) and
  # `6~` (Page Down) forms. We give CSI follow-bytes the same
  # 50ms window: under normal conditions they arrive in the same
  # write as `ESC [`, but a slow tty shouldn't drop arrow keys.
  defp parse_csi do
    case Bridge.read_key(@esc_timeout_ms) do
      {:ok, ?A} -> {:key, :up}
      {:ok, ?B} -> {:key, :down}
      {:ok, ?C} -> {:key, :right}
      {:ok, ?D} -> {:key, :left}
      {:ok, ?Z} -> {:key, :shift_tab}
      {:ok, ?5} -> consume_tilde(:page_up)
      {:ok, ?6} -> consume_tilde(:page_down)
      _ -> {:key, :unknown}
    end
  end

  defp consume_tilde(key) do
    case Bridge.read_key(@esc_timeout_ms) do
      {:ok, ?~} -> {:key, key}
      _ -> {:key, :unknown}
    end
  end
end
