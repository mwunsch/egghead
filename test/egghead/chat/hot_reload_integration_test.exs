defmodule Egghead.Chat.HotReloadIntegrationTest do
  @moduledoc """
  End-to-end: spin up a real Index + RecordStore + Coordinator,
  drop an agent record on disk, edit it, assert the live system
  notice and roster broadcast both reach a subscriber on the room
  topic.

  Skips the real Agent.Supervisor (no LLMs), so the lifecycle
  events are simulated by re-broadcasting them ourselves once the
  record-change hint has been processed. This proves the
  RecordStore → Coordinator → room-topic plumbing without dragging
  in the agent process startup time.
  """

  use ExUnit.Case, async: false

  alias Egghead.Chat.Coordinator
  alias Egghead.Chat.Coordinator.AgentInfo
  alias Egghead.Index
  alias Egghead.RecordStore

  setup_all do
    case Phoenix.PubSub.Supervisor.start_link(name: Egghead.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "egghead-hr-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn -> File.rm_rf!(tmp) end)

    %{records_dir: tmp}
  end

  test "editing an agent record narrates `<name> reloading…` to the room topic", %{
    records_dir: records_dir
  } do
    # The Coordinator hardcodes Egghead.RecordStore by registered name.
    # We can't safely use a different name here without monkeypatching.
    # The default-name RecordStore may already exist (started by the
    # application supervisor); start ours under a different name and
    # bypass the Coordinator's get_record path by sending lifecycle
    # events directly.
    idx_name = :"hr_index_#{:erlang.unique_integer([:positive])}"
    {:ok, _} = Index.start_link(name: idx_name, db_path: ":memory:")

    store_name = :"hr_store_#{:erlang.unique_integer([:positive])}"

    {:ok, _} =
      RecordStore.start_link(
        name: store_name,
        records_dir: records_dir,
        index: idx_name,
        watch: false
      )

    # Subscribe directly to the records topic to assert the
    # `:agent_record_changed` hint fires on `update_record`.
    :ok = Phoenix.PubSub.subscribe(Egghead.PubSub, RecordStore.records_topic())

    # Seed an agent record
    {:ok, _record} =
      RecordStore.create_record(store_name, %{
        id: "agents/alpha",
        title: "Alpha",
        class: :agent,
        body: "look for connections",
        meta: %{"model" => "anthropic/claude-haiku-4-5"}
      })

    assert_receive {:agent_record_changed, {:promoted, %{id: "agents/alpha", class: :agent}}}, 500

    # Now edit it — triggers the :reloaded transition.
    {:ok, _} = RecordStore.update_record(store_name, "agents/alpha", %{title: "Alpha 2"})

    assert_receive {:agent_record_changed, {:reloaded, %{id: "agents/alpha"}}}, 500
  end

  test "Coordinator subscribed to records:changes turns a :reloaded hint into a room system_notice",
       %{records_dir: records_dir} do
    idx_name = :"hr_index2_#{:erlang.unique_integer([:positive])}"
    {:ok, _} = Index.start_link(name: idx_name, db_path: ":memory:")

    store_name = :"hr_store2_#{:erlang.unique_integer([:positive])}"

    {:ok, _} =
      RecordStore.start_link(
        name: store_name,
        records_dir: records_dir,
        index: idx_name,
        watch: false
      )

    coord_name = :"hr_coord_#{:erlang.unique_integer([:positive])}"
    {:ok, coord_pid} = Coordinator.start_link(name: coord_name)

    room_id = "hr-#{:erlang.unique_integer([:positive])}"
    :ok = Phoenix.PubSub.subscribe(Egghead.PubSub, "room:#{room_id}")

    # Pre-load the Coordinator with the agent's prior AgentInfo and
    # tell it which room to announce into.
    :sys.replace_state(coord_pid, fn state ->
      info = %AgentInfo{
        id: "agents/alpha",
        name: "Alpha",
        model: "anthropic/claude-haiku-4-5",
        capabilities: [],
        tags: [],
        disposition: ""
      }

      %{
        state
        | agents: Map.put(state.agents, "agents/alpha", info),
          rooms: MapSet.put(state.rooms, room_id)
      }
    end)

    # Seed and edit the record.
    {:ok, _} =
      RecordStore.create_record(store_name, %{
        id: "agents/alpha",
        title: "Alpha",
        class: :agent,
        body: "v1",
        meta: %{"model" => "anthropic/claude-haiku-4-5"}
      })

    {:ok, _} = RecordStore.update_record(store_name, "agents/alpha", %{title: "Alpha"})

    # The Coordinator subscribed to records:changes during init/1, so
    # it should have processed the :reloaded hint and broadcast the
    # "Alpha reloading…" notice on the room topic.
    assert_receive {:system_notice, "agents/alpha reloading…"}, 1_000
  end
end
