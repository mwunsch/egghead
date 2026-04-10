defmodule Egghead.TUI.AppTest do
  use ExUnit.Case, async: true

  alias Egghead.TUI.App
  alias Egghead.TUI.Chat
  alias Egghead.TUI.Records

  # We avoid `App.init/1` here because the records screen's init
  # calls `RecordStore.list_records/0`, and the test environment
  # disables the RecordStore supervisor (config/test.exs sets
  # `start_record_store: false`). Constructing the App state with
  # default-valued screen models is enough to exercise the
  # routing wiring.
  defp build_state do
    %App{screen: :records, records: %Records.Model{}, chat: nil}
  end

  describe "screen routing" do
    test "the records `/chat` command bubbles a switch_screen cmd that the App handles" do
      state = build_state()

      # Drive records mode through the command palette: `/`,
      # then "chat", then Enter. App.update forwards to
      # Records.update, intercepts the resulting cmd, and
      # transitions to chat.
      state = drive(state, [{:char, "/"}, {:char, "c"}, {:char, "h"}, {:char, "a"}, {:char, "t"}])
      {state, _cmd} = App.update({:key, :enter}, state)

      assert state.screen == :chat
      assert is_struct(state.chat, Chat.Model)
    end

    test "F1 in chat mode switches back to records" do
      state = %App{screen: :chat, records: %Records.Model{}, chat: %Chat.Model{}}

      {state, _cmd} = App.update({:key, :f1}, state)

      assert state.screen == :records
    end

    test "F2 switches to chat when providers are available" do
      state = %App{screen: :records, records: %Records.Model{}, chat: nil, providers?: true}
      {state, _cmd} = App.update({:key, :f2}, state)
      assert state.screen == :chat
    end

    test "F2 is a no-op when no providers" do
      state = %App{screen: :records, records: %Records.Model{}, chat: nil, providers?: false}
      {state, _cmd} = App.update({:key, :f2}, state)
      assert state.screen == :records
    end

    test "the chat model survives a round trip through records mode" do
      original_chat = %Chat.Model{
        width: 99,
        height: 33,
        room_id: "marker-room",
        status_message: "marker"
      }

      state = %App{
        screen: :chat,
        records: %Records.Model{},
        chat: original_chat
      }

      # Chat → records via F1.
      {state, _} = App.update({:key, :f1}, state)
      assert state.screen == :records

      # Records → chat via the command palette.
      state = drive(state, [{:char, "/"}, {:char, "c"}, {:char, "h"}, {:char, "a"}, {:char, "t"}])
      {state, _} = App.update({:key, :enter}, state)
      assert state.screen == :chat

      assert state.chat.room_id == "marker-room",
             "App.handle_cmd should resume the existing chat model, not re-init"

      assert state.chat.status_message == "marker"
    end
  end

  describe "resize forwarding" do
    test "resize reaches the inactive screen too" do
      state = %App{
        screen: :records,
        records: %Records.Model{width: 80, height: 24},
        chat: %Chat.Model{width: 80, height: 24}
      }

      {state, _} = App.update({:resize, 120, 40}, state)

      assert state.records.width == 120
      assert state.records.height == 40
      assert state.chat.width == 120
      assert state.chat.height == 40
    end

    test "resize is harmless when the inactive screen has no model yet" do
      state = build_state()

      {state, _} = App.update({:resize, 100, 30}, state)

      assert state.records.width == 100
      assert state.records.height == 30
      assert state.chat == nil
    end
  end

  describe "view + subscriptions delegate to the active screen" do
    test "view returns a tree for whichever screen is active" do
      records_state = build_state()
      assert is_tuple(App.view(records_state))

      chat_state = %App{screen: :chat, records: nil, chat: %Chat.Model{}}
      assert is_tuple(App.view(chat_state))
    end

    test "subscriptions are delegated" do
      records_state = build_state()
      assert :keys in App.subscriptions(records_state)

      chat_state = %App{screen: :chat, records: nil, chat: %Chat.Model{}}
      assert :keys in App.subscriptions(chat_state)
    end
  end

  defp drive(state, msgs) do
    Enum.reduce(msgs, state, fn msg, acc ->
      {next, _cmd} = App.update(msg, acc)
      next
    end)
  end
end
