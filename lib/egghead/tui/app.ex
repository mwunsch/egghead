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
  """

  @behaviour Egghead.OpenTUI.Runtime

  alias Egghead.TUI.{Chat, Records}

  @type screen :: :records | :chat

  @type t :: %__MODULE__{
          screen: screen(),
          records: term() | nil,
          chat: term() | nil,
          providers?: boolean()
        }

  defstruct screen: :records, records: nil, chat: nil, providers?: false

  @impl true
  def init(opts) do
    {records_model, records_cmd} = Records.init(opts)
    has_providers = detect_providers()
    records_model = %{records_model | providers?: has_providers}

    state = %__MODULE__{
      screen: :records,
      records: records_model,
      providers?: has_providers
    }

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
  # F1 → Records, F2 → Chat (only if providers are configured).
  # Intercepted here so screens don't need to know about each other.
  def update({:key, :f1}, %__MODULE__{screen: :records} = state), do: {state, :none}

  def update({:key, :f1}, %__MODULE__{} = state) do
    handle_cmd({:switch_screen, :records, []}, state)
  end

  def update({:key, :f2}, %__MODULE__{screen: :chat} = state), do: {state, :none}

  def update({:key, :f2}, %__MODULE__{providers?: true} = state) do
    handle_cmd({:switch_screen, :chat, [room_id: default_room_id()]}, state)
  end

  def update({:key, :f2}, %__MODULE__{} = state), do: {state, :none}

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

        chat_model =
          chat_model
          |> seed_dimensions(state.records)
          |> Map.put(:providers?, state.providers?)

        {%{state | screen: :chat, chat: chat_model}, chat_cmd}

      existing ->
        requested_room = Keyword.get(init_arg || [], :room_id)

        chat =
          if requested_room && requested_room != existing.room_id do
            Egghead.TUI.Chat.Model.switch_room(existing, requested_room)
          else
            existing
          end

        {%{state | screen: :chat, chat: chat}, :none}
    end
  end

  defp handle_cmd({:switch_screen, :records, init_arg}, state) do
    model =
      case Keyword.get(init_arg, :preferred_id) do
        nil -> state.records
        id -> Egghead.TUI.Records.Model.reload(state.records, id)
      end

    {%{state | screen: :records, records: model}, :none}
  end

  # Anything we don't intercept is a normal runtime command and
  # passes through unchanged.
  defp handle_cmd(cmd, state), do: {state, cmd}

  defp seed_dimensions(chat_model, %{width: w, height: h}) do
    %{chat_model | width: w, height: h}
  end

  defp seed_dimensions(chat_model, _), do: chat_model

  defp detect_providers do
    try do
      Egghead.LLM.Registry.list_providers() != []
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  defp default_room_id do
    try do
      Egghead.default_room()
    rescue
      _ -> "default"
    catch
      _, _ -> "default"
    end
  end
end
