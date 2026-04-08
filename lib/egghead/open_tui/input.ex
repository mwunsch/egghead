defmodule Egghead.OpenTUI.Input do
  @moduledoc """
  Minimal raw-mode key reader for the spike.

  Reads directly from `/dev/tty` to bypass the BEAM group leader.
  Parses only what the spike needs: printable ASCII, escape, Ctrl+C,
  and the four CSI arrow keys. A real input reader (Kitty keyboard
  protocol, bracketed paste, mouse) is explicitly deferred.

  Returns one of:
    * `{:char, "x"}`      — a printable ASCII byte
    * `{:key, :escape}`   — bare ESC
    * `{:key, :ctrl_c}`   — ^C
    * `{:key, :backspace}` — DEL (0x7F)
    * `{:key, :up | :down | :left | :right}` — CSI arrow keys
    * `{:key, :unknown}`  — something we didn't recognize
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
      <<0x03>> ->
        {:key, :ctrl_c}

      <<0x1B>> ->
        parse_escape(tty)

      <<0x7F>> ->
        {:key, :backspace}

      <<byte>> when byte >= 0x20 and byte < 0x7F ->
        {:char, <<byte>>}

      <<byte>> ->
        {:key, {:byte, byte}}

      :eof ->
        {:key, :eof}
    end
  end

  defp parse_escape(tty) do
    case read_byte(tty) do
      :eof ->
        {:key, :escape}

      <<?[>> ->
        case read_byte(tty) do
          <<?A>> -> {:key, :up}
          <<?B>> -> {:key, :down}
          <<?C>> -> {:key, :right}
          <<?D>> -> {:key, :left}
          _ -> {:key, :unknown}
        end

      _ ->
        {:key, :escape}
    end
  end

  defp read_byte(tty) do
    case :file.read(tty, 1) do
      {:ok, bin} -> bin
      _ -> :eof
    end
  end
end
