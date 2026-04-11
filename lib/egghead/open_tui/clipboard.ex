defmodule Egghead.OpenTUI.Clipboard do
  @moduledoc """
  Cross-platform clipboard access via the OSC 52 escape sequence.

  OSC 52 sets the system clipboard by writing an escape sequence
  directly to the terminal. No platform-specific tools (`pbcopy`,
  `xclip`) are needed — the terminal emulator handles it.

  Supported by: iTerm2, kitty, WezTerm, Alacritty, ghostty,
  Windows Terminal, foot, and most modern terminals. Works over
  SSH sessions too.
  """

  @doc """
  Copy `text` to the system clipboard via OSC 52.

  Writes `ESC ] 52 ; c ; <base64> BEL` to `/dev/tty`.
  Returns `:ok` regardless of terminal support.
  """
  @spec copy(String.t()) :: :ok
  def copy(text) when is_binary(text) do
    encoded = Base.encode64(text)
    write_tty("\e]52;c;#{encoded}\a")
  end

  @doc """
  Clear the system clipboard via OSC 52.
  """
  @spec clear() :: :ok
  def clear do
    write_tty("\e]52;c;!\a")
  end

  defp write_tty(bytes) do
    case :file.open(~c"/dev/tty", [:write, :raw, :binary]) do
      {:ok, fd} ->
        _ = :file.write(fd, bytes)
        _ = :file.close(fd)
        :ok

      _ ->
        :ok
    end
  end
end
