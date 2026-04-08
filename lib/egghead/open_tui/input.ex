defmodule Egghead.OpenTUI.Input do
  @moduledoc """
  Raw-mode key reader.

  Reads directly from `/dev/tty` to bypass the BEAM group leader.
  Decodes printable ASCII, the common Ctrl+letter control bytes,
  backspace (DEL, 0x7F), the four CSI arrow keys, and the CSI
  Page Up / Page Down sequences. A fuller input reader (Kitty
  keyboard protocol, bracketed paste, mouse, focus events) is
  not yet implemented.

  Returns one of:
    * `{:char, "x"}` — a printable ASCII byte (0x20–0x7E)
    * `{:key, :escape}` — bare ESC
    * `{:key, :ctrl_a | :ctrl_c | :ctrl_e | :ctrl_f | :ctrl_k | :ctrl_l |
            :ctrl_n | :ctrl_p | :ctrl_q | :ctrl_t | :ctrl_u | :ctrl_w |
            :ctrl_z}`
    * `{:key, :alt_b | :alt_d | :alt_f | :alt_backspace}` — common
      Meta-key (Option-as-Meta) sequences for readline-style word
      movement and kill
    * `{:key, :backspace}` — DEL (0x7F)
    * `{:key, :tab}` — TAB (0x09)
    * `{:key, :enter}` — CR (0x0D) / LF (0x0A)
    * `{:key, :up | :down | :left | :right}` — CSI arrows
    * `{:key, :page_up | :page_down}` — CSI 5~ / 6~
    * `{:key, {:byte, n}}` — an unrecognized control byte
    * `{:key, :unknown}` — an unrecognized escape sequence
    * `{:key, :eof}` — the tty closed

  ## Known limitation: bare ESC blocks the parser

  After reading `0x1B`, the parser blocks waiting for the next
  byte to disambiguate `ESC alone` from `ESC + letter`
  (Meta-key) or `ESC [` (CSI). With our current
  blocking-`:file.read/2` implementation, pressing ESC alone
  freezes the screen until another key is pressed. The proper
  fix is a non-blocking read with a short (~50ms) disambiguation
  timeout. We don't hit this today because no current key
  binding uses bare ESC, but it's a real bug to fix when we
  start using ESC for command-mode exit / link deselect.
  """

  @doc """
  Block until one key is read from /dev/tty. Returns a parsed key.
  """
  def read_one_key do
    {:ok, tty} = :file.open(~c"/dev/tty", [:read, :raw, :binary])

    try do
      parse_next(tty)
    after
      :file.close(tty)
    end
  end

  defp parse_next(tty) do
    case read_byte(tty) do
      <<0x01>> -> {:key, :ctrl_a}
      <<0x03>> -> {:key, :ctrl_c}
      <<0x05>> -> {:key, :ctrl_e}
      <<0x06>> -> {:key, :ctrl_f}
      <<0x09>> -> {:key, :tab}
      <<0x0A>> -> {:key, :enter}
      <<0x0B>> -> {:key, :ctrl_k}
      <<0x0C>> -> {:key, :ctrl_l}
      <<0x0D>> -> {:key, :enter}
      <<0x0E>> -> {:key, :ctrl_n}
      <<0x10>> -> {:key, :ctrl_p}
      <<0x11>> -> {:key, :ctrl_q}
      <<0x14>> -> {:key, :ctrl_t}
      <<0x15>> -> {:key, :ctrl_u}
      <<0x17>> -> {:key, :ctrl_w}
      <<0x1A>> -> {:key, :ctrl_z}
      <<0x1B>> -> parse_escape(tty)
      <<0x7F>> -> {:key, :backspace}
      <<byte>> when byte >= 0x20 and byte < 0x7F -> {:char, <<byte>>}
      <<byte>> -> {:key, {:byte, byte}}
      :eof -> {:key, :eof}
    end
  end

  defp parse_escape(tty) do
    case read_byte(tty) do
      :eof ->
        {:key, :escape}

      <<?[>> ->
        parse_csi(tty)

      <<?b>> ->
        {:key, :alt_b}

      <<?d>> ->
        {:key, :alt_d}

      <<?f>> ->
        {:key, :alt_f}

      <<0x7F>> ->
        {:key, :alt_backspace}

      _ ->
        {:key, :escape}
    end
  end

  # CSI sequences after `ESC [`. Single-letter arrow forms
  # (`A`/`B`/`C`/`D`) and the digit-prefixed `5~` (Page Up) and
  # `6~` (Page Down) forms.
  defp parse_csi(tty) do
    case read_byte(tty) do
      <<?A>> -> {:key, :up}
      <<?B>> -> {:key, :down}
      <<?C>> -> {:key, :right}
      <<?D>> -> {:key, :left}
      <<?5>> -> consume_tilde(tty, :page_up)
      <<?6>> -> consume_tilde(tty, :page_down)
      _ -> {:key, :unknown}
    end
  end

  defp consume_tilde(tty, key) do
    case read_byte(tty) do
      <<?~>> -> {:key, key}
      _ -> {:key, :unknown}
    end
  end

  defp read_byte(tty) do
    case :file.read(tty, 1) do
      {:ok, bin} -> bin
      _ -> :eof
    end
  end
end
