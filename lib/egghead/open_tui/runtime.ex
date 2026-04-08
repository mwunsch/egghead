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
  @callback view(model(), {pos_integer(), pos_integer()}) :: Egghead.OpenTUI.View.tree()
  @callback subscriptions(model()) :: [subscription()]

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
      state = %{model: model, inbox: [], halt?: false}
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
      tree = behaviour.view(model, {width, height})
      Renderer.draw(handle, {0, 0, width, height}, tree)
    end)
  end

  # ---- message sources ----------------------------------------------------

  defp next_msg(_behaviour, %{inbox: [head | tail]} = state) do
    {head, %{state | inbox: tail}}
  end

  defp next_msg(behaviour, %{inbox: []} = state) do
    subs = behaviour.subscriptions(state.model)

    if :keys in subs do
      key = Input.read_one_key()

      # Default key→halt mapping. Screens can override by
      # *handling* :ctrl_c / :escape in their update/2 and
      # returning a non-:halt cmd.
      case key do
        {:key, :ctrl_c} -> {:halt, state}
        _ -> {key_to_msg(key), state}
      end
    else
      # No active subscription; nothing to wait on. Bail out.
      {:halt, state}
    end
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
