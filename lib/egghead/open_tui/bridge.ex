defmodule Egghead.OpenTUI.Bridge do
  @moduledoc """
  NIF bridge to OpenTUI's Zig core (spike scope).

  The native library is `priv/native/libbridge_nif.{dylib,so,dll}` and it
  loads `libopentui.{dylib,so,dll}` as a sibling via `@loader_path`
  (macOS) / `$ORIGIN` (Linux).

  ## Handle discipline

  All OpenTUI renderers live behind opaque integer handles registered in
  the Zig shim. Elixir never holds a raw pointer. A bogus handle returns
  `:badarg` — it cannot crash the BEAM.

  ## Current surface (spike only)

    * `create_renderer/2` — allocate renderer, return `{:ok, handle}`
    * `setup_terminal/1` — enter alternate screen, enable terminal features
    * `draw_hello/4` — clear buffer, draw centered text, flush a frame
    * `destroy_renderer/1` — tear down, restore terminal state

  This is not the final bridge. It exists to prove the NIF round-trip
  works end to end. See `records/design/opentui-bridge.md`.
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
  Clear the next buffer, draw `text` horizontally centered, render the
  frame. The caller must pass the same `width`/`height` it used for
  `create_renderer/2`.
  """
  @spec draw_hello(
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          binary()
        ) :: :ok
  def draw_hello(_handle, _width, _height, _text),
    do: :erlang.nif_error(:nif_not_loaded)

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
end
