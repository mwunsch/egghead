defmodule Egghead.OpenTUI.Bridge do
  @moduledoc """
  NIF bridge to OpenTUI's Zig core.

  The native library is installed by `build_dot_zig` at
  `priv/<target>/lib/libbridge_nif.so` and loads
  `libopentui.{dylib,so}` as a sibling via `@loader_path`
  (macOS) / `$ORIGIN` (Linux). The exact target subdirectory is
  resolved at load time by `load_nif/0`.

  ## Handle discipline

  All OpenTUI renderers live behind opaque integer handles
  registered in the Zig shim. Elixir never holds a raw pointer.
  A bogus handle returns `:badarg` — it cannot crash the BEAM.

  ## Surface

  Lifecycle:
    * `create_renderer/2`, `setup_terminal/1`, `destroy_renderer/1`
    * `enter_raw_mode/0`, `leave_raw_mode/0`
    * `tty_size/0`, `drain_input/1`, `resize/3`

  Per-frame drawing:
    * `begin_frame/1`, `end_frame/1`
    * `clear/2`, `fill_rect/6`, `draw_text/7`
  """

  @on_load :load_nif

  @doc false
  def load_nif do
    # build_dot_zig installs to priv/<target>/lib/. We don't know the
    # exact target subdir at load time, so resolve it by globbing for
    # the bridge_nif file under priv/. Exactly one match is expected.
    priv = :code.priv_dir(:egghead) |> List.to_string()

    path =
      case Path.wildcard(Path.join(priv, "*/lib/libbridge_nif.*")) do
        [match | _] ->
          # load_nif wants the path WITHOUT extension; it picks the right one.
          Path.join(Path.dirname(match), "libbridge_nif")

        [] ->
          raise "could not find libbridge_nif under #{priv} — did `mix compile` succeed?"
      end

    case :erlang.load_nif(String.to_charlist(path), 0) do
      :ok ->
        :ok

      {:error, {:load_failed, reason}} ->
        raise "failed to load bridge NIF at #{path}: #{reason}"

      {:error, reason} ->
        raise "failed to load bridge NIF at #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Allocate a new OpenTUI renderer sized to `width` x `height` cells.

  Returns `{:ok, handle}` or `{:error, reason}`.
  """
  @spec create_renderer(pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def create_renderer(_width, _height), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Bind the renderer to the terminal: alternate screen, cursor save,
  terminal capability detection, Kitty keyboard protocol if available.

  Must be called exactly once per renderer before any draw call.
  """
  @spec setup_terminal(non_neg_integer()) :: :ok
  def setup_terminal(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Tear down the renderer. Restores terminal state (exits alt screen,
  resets modes) as part of OpenTUI's shutdown sequence.
  """
  @spec destroy_renderer(non_neg_integer()) :: :ok
  def destroy_renderer(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Put the controlling terminal into raw mode via termios, opening
  `/dev/tty` directly. Saves the prior state for `leave_raw_mode/0`.

  Lives in the NIF because BEAM ports don't inherit the controlling
  terminal, so subprocess `stty` calls cannot reach it.
  """
  @spec enter_raw_mode() :: :ok | {:error, atom()}
  def enter_raw_mode, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Restore the termios state captured by `enter_raw_mode/0`."
  @spec leave_raw_mode() :: :ok
  def leave_raw_mode, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Return `{:ok, {cols, rows}}` via `ioctl(TIOCGWINSZ)` on `/dev/tty`."
  @spec tty_size() :: {:ok, {pos_integer(), pos_integer()}} | {:error, atom()}
  def tty_size, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Consume and discard any bytes pending on `/dev/tty` within
  `timeout_ms`. Used to swallow OpenTUI's terminal-capability query
  responses after `setup_terminal/1` so they don't get misread as
  user keypresses by the Elixir input reader.
  """
  @spec drain_input(non_neg_integer()) :: :ok
  def drain_input(_timeout_ms), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Begin a new frame on `handle`. Caches OpenTUI's back buffer in the
  shim's per-handle state so subsequent `clear/2` and `draw_text/7`
  calls don't have to re-resolve it. Must be paired with `end_frame/1`.
  """
  @spec begin_frame(non_neg_integer()) :: :ok
  def begin_frame(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Clear the back buffer to `bg`. `bg` is a 16-byte binary holding four
  little-endian f32s (r, g, b, a) — see `Egghead.OpenTUI.Colors`.
  """
  @spec clear(non_neg_integer(), binary()) :: :ok
  def clear(_handle, _bg), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Draw `text` at `(x, y)` with the given fg/bg color binaries and
  attribute bitfield. Pass `""` (empty binary) for `bg` to mean
  transparent.
  """
  @spec draw_text(
          non_neg_integer(),
          binary(),
          non_neg_integer(),
          non_neg_integer(),
          binary(),
          binary(),
          non_neg_integer()
        ) :: :ok
  def draw_text(_handle, _text, _x, _y, _fg, _bg, _attrs),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Flush the frame: calls OpenTUI's diff renderer with `force=false`
  and clears the cached back buffer.
  """
  @spec end_frame(non_neg_integer()) :: :ok
  def end_frame(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Fill a rectangular region of the back buffer with `bg`. `bg` is a
  16-byte color binary (see `Egghead.OpenTUI.Colors`). Used for
  pane backgrounds, dividers, status bars.
  """
  @spec fill_rect(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          binary()
        ) :: :ok
  def fill_rect(_handle, _x, _y, _w, _h, _bg),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Resize the renderer to `(width, height)`. Call after detecting a
  terminal size change (e.g. via `tty_size/0` polling).
  """
  @spec resize(non_neg_integer(), pos_integer(), pos_integer()) :: :ok
  def resize(_handle, _width, _height),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Place (or hide) the terminal's text cursor at `(x, y)`.

  When `visible` is `true`, OpenTUI emits the ANSI escape to
  position the cursor and show it; the terminal then highlights
  the cell at that coordinate using whatever cursor style is
  configured (block by default in most terminals). When `false`,
  the cursor is hidden.

  This is the right way to render an in-line text cursor — the
  alternative (drawing a glyph like `▌` into the buffer) takes
  up its own column and shifts the surrounding content.
  """
  @spec set_cursor_position(non_neg_integer(), non_neg_integer(), non_neg_integer(), boolean()) :: :ok
  def set_cursor_position(_handle, _x, _y, _visible),
    do: :erlang.nif_error(:nif_not_loaded)
end
