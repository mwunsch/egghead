defmodule Egghead.OpenTUI.Runtime do
  @moduledoc """
  Elm-style runtime for OpenTUI screens.

  A screen module implements this behaviour with four callbacks:

    * `init/1` — produces the initial model and any startup
      command (e.g. fetching data from disk).
    * `update/2` — pure reducer. Given a message and a model,
      returns a new model and a command.
    * `view/2` — pure view function. Given a model and the
      current terminal dimensions, returns a
      `Egghead.OpenTUI.View.tree`.
    * `subscriptions/1` — declares which message sources the
      runtime should pull from. Currently `:keys` is the only
      supported source; `{:interval, ms, msg}` is reserved.

  ## Loop

  ```
  init → {model, cmd}
  execute(cmd)              # may push msgs onto inbox
  loop:
    tree = view(model)
    Renderer.draw(handle, viewport, tree)
    msg = next_msg(model)   # inbox first, then input if :keys subscribed
    {model, cmd} = update(msg, model)
    execute(cmd)
    loop
  ```

  ## Commands

  A command is a description of a side effect. The runtime
  executes them on behalf of the screen so the screen stays
  pure:

    * `:none` — do nothing
    * `{:exec, fn}` — run `fn.()` in the runtime process; if
      it returns a non-`:no_msg` value, that value is queued as
      the next message to dispatch
    * `{:suspend, fn}` — tear down the OpenTUI terminal, run
      `fn.()` (typically a blocking external program like
      `$EDITOR`), restore the terminal, and queue the function's
      return value as a message
    * `{:batch, [cmd, ...]}` — execute commands in order, queue
      all produced messages
    * `:halt` — exit the runtime cleanly (the screen's exit path)

  ## Suspending the terminal

  `{:suspend, fn}` is the runtime's headline feature compared
  to TermUI on `main`, which uses `Application.put_env` and
  `:quit` to communicate "spawn $EDITOR." Here, the screen's
  `update/2` returns a `{:suspend, fn}` command and the runtime
  handles tear-down and resume. The function runs while the
  terminal is in cooked mode and out of the alt screen, so it
  can drive vim, less, or anything else that wants the tty.
  """

  alias Egghead.OpenTUI.{Bridge, Input, Renderer, Terminal}

  @type model :: term()
  @type msg :: term()
  @type cmd ::
          :none
          | :halt
          | {:exec, (-> term())}
          | {:suspend, (-> term())}
          | {:batch, [cmd()]}

  @type subscription :: :keys | {:interval, pos_integer(), msg()}

  @callback init(opts :: keyword()) :: {model(), cmd()}
  @callback update(msg(), model()) :: {model(), cmd()}
  @callback view(model()) :: Egghead.OpenTUI.View.tree()
  @callback subscriptions(model()) :: [subscription()]

  @typedoc """
  Synthetic message the runtime dispatches into `update/2` whenever
  the terminal dimensions change. The first dispatch happens
  before the first draw so the screen always has a current size
  in its model.
  """
  @type resize_msg :: {:resize, pos_integer(), pos_integer()}

  @doc """
  Boot the runtime for `behaviour` with the given `opts`. Owns
  the Terminal GenServer for the duration of the loop and tears
  it down on normal or abnormal exit.

  Blocks until the screen returns `:halt` or an `:escape` /
  `:ctrl_c` key (the runtime maps these to `:halt` by default
  if the screen's `update/2` returns the model unchanged).
  """
  @spec run(module(), keyword()) :: :ok | {:error, term()}
  def run(behaviour, opts \\ []) do
    redirect_logger(opts)

    {:ok, _pid} = Terminal.start_link()

    try do
      :ok = Bridge.drain_input(300)

      {model, cmd} = behaviour.init(opts)
      state = %{model: model, inbox: [], halt?: false, last_dimensions: nil}
      state = execute(cmd, state, behaviour)

      loop(behaviour, state)
    after
      try do
        GenServer.stop(Terminal, :normal)
      catch
        _, _ -> :ok
      end
    end
  end

  # ---- main loop ----------------------------------------------------------

  defp loop(_behaviour, %{halt?: true}), do: :ok

  defp loop(behaviour, state) do
    state = sync_dimensions(behaviour, state)
    :ok = draw(behaviour, state.model)

    {msg, state} = next_msg(behaviour, state)

    case msg do
      :halt ->
        :ok

      _ ->
        {model, cmd} = behaviour.update(msg, state.model)
        state = %{state | model: model}
        state = execute(cmd, state, behaviour)
        loop(behaviour, state)
    end
  end

  defp draw(behaviour, model) do
    Terminal.with_handle(fn handle, width, height ->
      tree = behaviour.view(model)
      Renderer.draw(handle, {0, 0, width, height}, tree)
    end)
  end

  # Pre-loop dimensions check. Polls Terminal once per iteration;
  # if the size has changed since the last :resize dispatch (or
  # if there's never been one), synthesizes a `{:resize, w, h}`
  # message and runs it through the screen's update/2 + cmd
  # pipeline before the draw. This is how Elm-style screens stay
  # in sync with the terminal — model owns its own dimensions.
  defp sync_dimensions(behaviour, state) do
    {w, h} = Terminal.dimensions()

    if {w, h} != state.last_dimensions do
      {model, cmd} = behaviour.update({:resize, w, h}, state.model)
      state = %{state | model: model, last_dimensions: {w, h}}
      execute(cmd, state, behaviour)
    else
      state
    end
  end

  # ---- message sources ----------------------------------------------------

  defp next_msg(_behaviour, %{inbox: [head | tail]} = state) do
    {head, %{state | inbox: tail}}
  end

  defp next_msg(behaviour, %{inbox: []} = state) do
    subs = behaviour.subscriptions(state.model)

    if :keys in subs do
      key = Input.read_one_key()

      # Runtime-level key intercepts. These bypass the screen's
      # update/2 entirely so any screen gets the same convention.
      case key do
        {:key, :ctrl_c} ->
          {:halt, state}

        {:key, :ctrl_q} ->
          {:halt, state}

        {:key, :ctrl_z} ->
          # Suspend to background. Tear the terminal down (the
          # user's shell takes back the tty), send SIGSTOP to
          # ourselves, and wait. When the user runs `fg`, the
          # kernel sends SIGCONT, the BEAM resumes, and we
          # restore the terminal. Returning :no_msg lets the
          # loop fall through cleanly; clearing last_dimensions
          # forces the next sync_dimensions/2 to dispatch a
          # fresh :resize in case the window changed while we
          # were stopped.
          suspend_to_background()
          {:no_msg, %{state | last_dimensions: nil}}

        _ ->
          {key_to_msg(key), state}
      end
    else
      # No active subscription; nothing to wait on. Bail out.
      {:halt, state}
    end
  end

  # Suspend the BEAM to the background, the way Ctrl+Z does for
  # any well-behaved POSIX program. Because we're in raw mode,
  # the kernel doesn't generate SIGTSTP from Ctrl+Z (cfmakeraw
  # disables ISIG); we receive 0x1A as a normal byte and have to
  # do the work ourselves.
  #
  # 1. Tear down the OpenTUI renderer + raw mode so the user's
  #    shell sees a sane tty when control returns.
  # 2. Send SIGSTOP to our own pid via `kill`. SIGSTOP can't be
  #    caught or ignored, so the BEAM will stop here. The
  #    System.cmd call doesn't return until SIGCONT (i.e. `fg`)
  #    wakes us back up.
  # 3. Re-create the renderer + raw mode and drain any pending
  #    bytes (the resumed shell may have written to stdin).
  # 4. Force the next sync_dimensions/2 call to re-read the size
  #    by clearing last_dimensions on return — handled by the
  #    caller via the loop's natural pre-draw sync.
  defp suspend_to_background do
    :ok = Terminal.suspend()

    pid = "#{:os.getpid()}"
    _ = System.cmd("kill", ["-STOP", pid])

    :ok = Terminal.resume()
    :ok = Bridge.drain_input(300)
    :ok
  end

  # The runtime hands key events through unchanged. Screens
  # pattern-match on `{:key, atom}` and `{:char, binary}` shapes
  # in their update/2 functions, the same shapes
  # `Egghead.OpenTUI.Input` produces.
  defp key_to_msg(key), do: key

  # ---- command execution --------------------------------------------------

  defp execute(:none, state, _behaviour), do: state

  defp execute(:halt, state, _behaviour), do: %{state | halt?: true}

  defp execute({:batch, cmds}, state, behaviour) do
    Enum.reduce(cmds, state, fn cmd, acc -> execute(cmd, acc, behaviour) end)
  end

  defp execute({:exec, fun}, state, _behaviour) when is_function(fun, 0) do
    case fun.() do
      :no_msg -> state
      nil -> state
      msg -> %{state | inbox: state.inbox ++ [msg]}
    end
  end

  defp execute({:suspend, fun}, state, _behaviour) when is_function(fun, 0) do
    :ok = Terminal.suspend()

    result =
      try do
        fun.()
      catch
        kind, reason ->
          {:suspend_error, kind, reason}
      end

    :ok = Terminal.resume()
    :ok = Bridge.drain_input(300)

    case result do
      :no_msg -> state
      nil -> state
      msg -> %{state | inbox: state.inbox ++ [msg]}
    end
  end

  # ---- logger plumbing ----------------------------------------------------

  defp redirect_logger(opts) do
    log_path =
      Keyword.get(
        opts,
        :log_path,
        Path.join(System.tmp_dir!(), "opentui-runtime.log")
      )

    try do
      :logger.remove_handler(:default)
    catch
      _, _ -> :ok
    end

    :logger.add_handler(:runtime_file, :logger_std_h, %{
      config: %{file: String.to_charlist(log_path)}
    })

    :ok
  end
end
