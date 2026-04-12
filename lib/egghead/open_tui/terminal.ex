defmodule Egghead.OpenTUI.Terminal do
  @moduledoc """
  Owns the terminal lifecycle for a single TUI session.

  OpenTUI's `setupTerminal` enters the alternate screen, saves
  cursor state, detects terminal capabilities, and enables the
  Kitty keyboard protocol — but it does NOT put the tty into raw
  mode. We do that ourselves through the bridge's
  `enter_raw_mode/0`. On teardown, `destroyRenderer` restores
  everything OpenTUI touched; this GenServer additionally
  restores the saved termios state.

  The GenServer traps exits and runs cleanup in `terminate/2` so
  an abnormal shutdown (crash, kill, Ctrl+C) still leaves the
  terminal usable.
  """

  use GenServer

  alias Egghead.OpenTUI.Bridge

  # ---- API -----------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return the active renderer handle."
  def handle, do: GenServer.call(__MODULE__, :handle)

  @doc "Return the renderer dimensions {width, height} in cells."
  def dimensions, do: GenServer.call(__MODULE__, :dimensions)

  @doc """
  Run `fun.(handle, width, height)` inside the GenServer so the
  draw sequence (begin_frame → draw calls → end_frame) is owned
  by the single terminal process. The function's return value is
  passed back to the caller.
  """
  def with_handle(fun) when is_function(fun, 3) do
    GenServer.call(__MODULE__, {:with_handle, fun})
  end

  @doc """
  Resize the renderer to `(width, height)` and update the cached
  dimensions. Call after detecting a terminal size change.
  """
  def resize(width, height) when is_integer(width) and is_integer(height) do
    GenServer.call(__MODULE__, {:resize, width, height})
  end

  @doc """
  Tear down the OpenTUI renderer and leave raw mode so a foreign
  process (e.g. `$EDITOR`) can take over the controlling terminal.
  Use `resume/0` to restore the renderer afterwards. Idempotent.
  """
  def suspend, do: GenServer.call(__MODULE__, :suspend)

  @doc """
  Re-enter raw mode and create a new OpenTUI renderer at the
  current TTY size. The handle changes; existing handles from
  before `suspend/0` are invalid. Idempotent if not currently
  suspended.
  """
  def resume, do: GenServer.call(__MODULE__, :resume)

  # ---- Callbacks -----------------------------------------------------------

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    {width, height} =
      case Bridge.tty_size() do
        {:ok, {cols, rows}} -> {cols, rows}
        _ -> {80, 24}
      end

    :ok = Bridge.enter_raw_mode()

    {:ok, handle} = Bridge.create_renderer(width, height)
    :ok = Bridge.setup_terminal(handle)
    :ok = Bridge.enable_mouse(handle, false)
    :ok = enable_bracketed_paste()

    state = %{handle: handle, width: width, height: height, suspended?: false}
    {:ok, state}
  end

  @impl true
  def handle_call(:handle, _from, state), do: {:reply, state.handle, state}

  def handle_call(:dimensions, _from, state),
    do: {:reply, {state.width, state.height}, state}

  def handle_call({:with_handle, fun}, _from, state) do
    reply = fun.(state.handle, state.width, state.height)
    {:reply, reply, state}
  end

  def handle_call({:resize, width, height}, _from, state) do
    :ok = Bridge.resize(state.handle, width, height)
    {:reply, :ok, %{state | width: width, height: height}}
  end

  def handle_call(:suspend, _from, %{suspended?: true} = state),
    do: {:reply, :ok, state}

  def handle_call(:suspend, _from, state) do
    safe(fn -> disable_bracketed_paste() end)
    safe(fn -> Bridge.destroy_renderer(state.handle) end)
    safe(fn -> Bridge.leave_raw_mode() end)
    {:reply, :ok, %{state | handle: nil, suspended?: true}}
  end

  def handle_call(:resume, _from, %{suspended?: false} = state),
    do: {:reply, :ok, state}

  def handle_call(:resume, _from, state) do
    {width, height} =
      case Bridge.tty_size() do
        {:ok, {cols, rows}} -> {cols, rows}
        _ -> {state.width, state.height}
      end

    :ok = Bridge.enter_raw_mode()
    {:ok, handle} = Bridge.create_renderer(width, height)
    :ok = Bridge.setup_terminal(handle)
    :ok = Bridge.enable_mouse(handle, false)
    :ok = enable_bracketed_paste()

    {:reply, :ok, %{state | handle: handle, width: width, height: height, suspended?: false}}
  end

  @impl true
  def terminate(_reason, state) do
    # OpenTUI restores alt screen + terminal modes inside destroyRenderer.
    # We restore termios afterwards so raw mode is off even on crash.
    safe(fn -> disable_bracketed_paste() end)

    if state.handle do
      safe(fn -> Bridge.destroy_renderer(state.handle) end)
    end

    safe(fn -> Bridge.leave_raw_mode() end)
    :ok
  end

  # ---- helpers -------------------------------------------------------------

  defp safe(f) do
    try do
      f.()
    catch
      _, _ -> :ok
    end
  end

  # Bracketed paste mode (xterm DECSET 2004). When enabled, the
  # terminal wraps pasted bytes in `ESC[200~ … ESC[201~` so we can
  # tell typed input from pasted input. The `Egghead.OpenTUI.Input`
  # parser already decodes the wrapper into `{:paste, text}`; this
  # is the wire-level enable that the parser depends on.
  #
  # We write to /dev/tty directly rather than through stdout so the
  # sequence isn't dependent on the BEAM's group leader plumbing.
  defp enable_bracketed_paste, do: write_tty("\e[?2004h")
  defp disable_bracketed_paste, do: write_tty("\e[?2004l")

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
