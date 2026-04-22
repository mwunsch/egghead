defmodule Egghead.RecordStoreTest do
  @moduledoc """
  Tests the agent-record transition classification — what kind of
  thing happened when a file under `records/` changed, from the
  perspective of the agent layer (promote / reload / rename / demote /
  remove / noop).

  Pure unit tests against `classify_agent_transition/2` are exhaustive
  and fast. End-to-end tests in `Egghead.Chat.HotReloadIntegrationTest`
  cover the broadcast-and-narrate side of the same flow.
  """

  use ExUnit.Case, async: false

  alias Egghead.Index
  alias Egghead.Record
  alias Egghead.RecordStore

  defp record(attrs) do
    defaults = %{
      id: "rec_#{:erlang.unique_integer([:positive])}",
      title: nil,
      class: :durable,
      body: "",
      tags: [],
      links: [],
      wikilinks: [],
      source_path: "/tmp/test/x.md"
    }

    struct!(Record, Map.merge(defaults, attrs))
  end

  describe "classify_agent_transition/2" do
    test "noop: nothing-there + non-agent file appearing" do
      assert :noop = RecordStore.classify_agent_transition(:none, record(%{class: :durable}))
    end

    test "noop: missing on both sides" do
      assert :noop = RecordStore.classify_agent_transition(:none, nil)
    end

    test "noop: non-agent file getting edited" do
      prev = {:ok, %{id: "notes/foo", class: :durable}}
      assert :noop = RecordStore.classify_agent_transition(prev, record(%{class: :durable}))
    end

    test "promoted: brand-new agent record at this path" do
      r = record(%{id: "agents/alpha", class: :agent})
      assert {:promoted, ^r} = RecordStore.classify_agent_transition(:none, r)
    end

    test "promoted: an existing non-agent record was rewritten as an agent" do
      prev = {:ok, %{id: "agents/alpha", class: :durable}}
      r = record(%{id: "agents/alpha", class: :agent})
      assert {:promoted, ^r} = RecordStore.classify_agent_transition(prev, r)
    end

    test "reloaded: same id, same class" do
      prev = {:ok, %{id: "agents/alpha", class: :agent}}
      r = record(%{id: "agents/alpha", class: :agent})
      assert {:reloaded, ^r} = RecordStore.classify_agent_transition(prev, r)
    end

    test "renamed: in-place id change, still agent class" do
      prev = {:ok, %{id: "agents/alpha", class: :agent}}
      r = record(%{id: "agents/beta", class: :agent})

      assert {:renamed, "agents/alpha", ^r} =
               RecordStore.classify_agent_transition(prev, r)
    end

    test "demoted: agent record edited to drop class: agent" do
      prev = {:ok, %{id: "agents/alpha", class: :agent}}
      r = record(%{id: "agents/alpha", class: :durable})

      assert {:demoted, "agents/alpha"} =
               RecordStore.classify_agent_transition(prev, r)
    end

    test "removed: agent file deleted" do
      prev = {:ok, %{id: "agents/alpha", class: :agent}}

      assert {:removed, "agents/alpha"} =
               RecordStore.classify_agent_transition(prev, nil)
    end

    test "removed-noop: non-agent file deleted (we don't care)" do
      prev = {:ok, %{id: "notes/foo", class: :durable}}
      assert :noop = RecordStore.classify_agent_transition(prev, nil)
    end
  end

  describe "FSEvents double-fire dedup" do
    setup do
      case Phoenix.PubSub.Supervisor.start_link(name: Egghead.PubSub) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      tmp = Path.join(System.tmp_dir!(), "egghead-dedup-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      %{records_dir: tmp}
    end

    test "two file_event messages with the same fingerprint broadcast only once",
         %{records_dir: dir} do
      {store_pid, path} = setup_store(dir, "dedup1", "alpha.md")

      File.write!(path, """
      ---
      id: agents/alpha1
      class: agent
      ---

      # Alpha
      """)

      :ok = Phoenix.PubSub.subscribe(Egghead.PubSub, RecordStore.records_topic())

      send(store_pid, {:file_event, self(), {path, [:created]}})
      send(store_pid, {:file_event, self(), {path, [:modified]}})

      # Force the GenServer to drain its mailbox.
      _ = :sys.get_state(store_pid)
      _ = :sys.get_state(store_pid)

      # Should see the agent_record_changed event exactly once.
      assert_receive {:agent_record_changed, {:promoted, _}}, 500
      refute_receive {:agent_record_changed, _}, 200
    end

    test "after a real edit (different fingerprint), the second event fires again",
         %{records_dir: dir} do
      {store_pid, path} = setup_store(dir, "dedup2", "alpha.md")

      File.write!(path, "---\nid: agents/alpha2\nclass: agent\n---\n\n# Alpha v1\n")
      :ok = Phoenix.PubSub.subscribe(Egghead.PubSub, RecordStore.records_topic())

      send(store_pid, {:file_event, self(), {path, [:created]}})
      _ = :sys.get_state(store_pid)
      assert_receive {:agent_record_changed, {:promoted, _}}, 500

      # Sleep long enough that mtime advances at second granularity,
      # then rewrite to bump fingerprint.
      Process.sleep(1_100)
      File.write!(path, "---\nid: agents/alpha2\nclass: agent\n---\n\n# Alpha v2\n")
      send(store_pid, {:file_event, self(), {path, [:modified]}})
      _ = :sys.get_state(store_pid)
      assert_receive {:agent_record_changed, {:reloaded, _}}, 500
    end

    # Wraps RecordStore.start_link and resolves the records_dir the
    # same way init/1 does (Path.expand + symlink resolution). On
    # macOS the tmp dir is a /var → /private/var symlink; without the
    # resolution, file paths the test sends in :file_event messages
    # don't compare equal to state.records_dir and `in_dir?` rejects
    # them silently.
    defp setup_store(dir, tag, file) do
      idx = :"dedup_idx_#{tag}_#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Index.start_link(name: idx, db_path: ":memory:")

      store = :"dedup_store_#{tag}_#{:erlang.unique_integer([:positive])}"

      {:ok, store_pid} =
        RecordStore.start_link(
          name: store,
          records_dir: dir,
          index: idx,
          watch: false
        )

      resolved_dir = :sys.get_state(store_pid).records_dir
      {store_pid, Path.join(resolved_dir, file)}
    end
  end
end
