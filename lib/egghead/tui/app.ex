defmodule Egghead.TUI.App do
  @moduledoc """
  Top-level shell for the OpenTUI runtime. Multiplexes between
  the records-list screen and the chat screen.

  The shell is the single behaviour the runtime drives. Each
  screen module (`Egghead.TUI.Records`, `Egghead.TUI.Chat`)
  follows the same callback shape as `Egghead.OpenTUI.Runtime`,
  but is wrapped here rather than launched directly. The shell
  forwards `update/2`, `view/1`, and `subscriptions/1` to the
  active screen and keeps the inactive screen's model around so
  round trips don't lose state (filter, scroll, transcript, …).

  ## Screen-level commands

  A child screen triggers a transition by returning a special
  command tuple from its `update/2`:

      {:switch_screen, target, init_arg}

  The shell intercepts these in `handle_cmd/2` — the underlying
  `Egghead.OpenTUI.Runtime` never sees them, so the runtime stays
  generic. On first switch into a screen, the shell calls that
  screen's `init/1` lazily; subsequent switches just flip the
  active screen and resume the existing model.

  Phase 6a wires routing only — chat is a placeholder. Phases 6c
  onward fill in the chat screen.
  """

  @behaviour Egghead.OpenTUI.Runtime

  alias Egghead.TUI.{Chat, Records}

  @type screen :: :records | :chat

  @type t :: %__MODULE__{
          screen: screen(),
          records: term() | nil,
          chat: term() | nil
        }

  defstruct screen: :records, records: nil, chat: nil

  @impl true
  def init(opts) do
    {records_model, records_cmd} = Records.init(opts)
    state = %__MODULE__{screen: :records, records: records_model}
    {state, records_cmd}
  end

  @impl true
  def view(%__MODULE__{screen: :records, records: m}), do: Records.view(m)
  def view(%__MODULE__{screen: :chat, chat: m}), do: Chat.view(m)

  @impl true
  def subscriptions(%__MODULE__{screen: :records, records: m}),
    do: Records.subscriptions(m)

  def subscriptions(%__MODULE__{screen: :chat, chat: m}),
    do: Chat.subscriptions(m)

  @impl true
  def update(msg, %__MODULE__{screen: :records, records: rm} = state) do
    # Resize messages must reach every screen the model owns so
    # the inactive one is correctly sized when the user switches
    # back to it. The active screen's update happens first; the
    # inactive screen receives the resize as a side effect.
    {new_rm, cmd} = Records.update(msg, rm)
    state = %{state | records: new_rm}
    state = forward_resize_to_inactive(msg, state)
    handle_cmd(cmd, state)
  end

  def update(msg, %__MODULE__{screen: :chat, chat: cm} = state) do
    {new_cm, cmd} = Chat.update(msg, cm)
    state = %{state | chat: new_cm}
    state = forward_resize_to_inactive(msg, state)
    handle_cmd(cmd, state)
  end

  # ---- internals ----------------------------------------------------------

  defp forward_resize_to_inactive({:resize, _w, _h} = msg, state) do
    case state.screen do
      :records when not is_nil(state.chat) ->
        {new_cm, _cmd} = Chat.update(msg, state.chat)
        %{state | chat: new_cm}

      :chat ->
        {new_rm, _cmd} = Records.update(msg, state.records)
        %{state | records: new_rm}

      _ ->
        state
    end
  end

  defp forward_resize_to_inactive(_msg, state), do: state

  # Switch into chat. Lazily initialise on first entry; subsequent
  # entries resume the existing model so the transcript and input
  # state survive round trips through records mode.
  #
  # Lazy init means a fresh chat model carries its struct defaults
  # (80x24) and won't see a `{:resize, w, h}` until the terminal
  # actually changes size. We seed it with the records model's
  # current dimensions so the very first frame is sized correctly.
  defp handle_cmd({:switch_screen, :chat, init_arg}, state) do
    case state.chat do
      nil ->
        {chat_model, chat_cmd} = Chat.init(init_arg || [])
        chat_model = seed_dimensions(chat_model, state.records)
        {%{state | screen: :chat, chat: chat_model}, chat_cmd}

      _existing ->
        {%{state | screen: :chat}, :none}
    end
  end

  defp handle_cmd({:switch_screen, :records, _init_arg}, state) do
    {%{state | screen: :records}, :none}
  end

  # Anything we don't intercept is a normal runtime command and
  # passes through unchanged.
  defp handle_cmd(cmd, state), do: {state, cmd}

  defp seed_dimensions(chat_model, %{width: w, height: h}) do
    %{chat_model | width: w, height: h}
  end

  defp seed_dimensions(chat_model, _), do: chat_model
end
