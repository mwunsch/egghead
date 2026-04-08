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
    * `{:key, :ctrl_c | :ctrl_f | :ctrl_n | :ctrl_p | :ctrl_q | :ctrl_t}`
    * `{:key, :backspace}` — DEL (0x7F)
    * `{:key, :tab}` — TAB (0x09)
    * `{:key, :enter}` — CR (0x0D) / LF (0x0A)
    * `{:key, :up | :down | :left | :right}` — CSI arrows
    * `{:key, :page_up | :page_down}` — CSI 5~ / 6~
    * `{:key, {:byte, n}}` — an unrecognized control byte
    * `{:key, :unknown}` — an unrecognized escape sequence
    * `{:key, :eof}` — the tty closed
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
      <<0x03>> -> {:key, :ctrl_c}
      <<0x06>> -> {:key, :ctrl_f}
      <<0x09>> -> {:key, :tab}
      <<0x0A>> -> {:key, :enter}
      <<0x0D>> -> {:key, :enter}
      <<0x0E>> -> {:key, :ctrl_n}
      <<0x10>> -> {:key, :ctrl_p}
      <<0x11>> -> {:key, :ctrl_q}
      <<0x14>> -> {:key, :ctrl_t}
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
