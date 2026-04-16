defmodule Egghead.Doc.ConcurrentTest do
  @moduledoc """
  Phase 2 tests: multi-client concurrent editing, convergence,
  external file writes mid-flight, and disconnect/reconnect safety.
  """
  use ExUnit.Case, async: false

  alias Egghead.Doc.Server
  alias Egghead.Test.YjsClient

  @moduletag :records

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "egghead_concurrent_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    db_path = Path.join(tmp_dir, ".egghead/index.db")
    File.mkdir_p!(Path.dirname(db_path))

    start_supervised!({Registry, keys: :unique, name: Egghead.Doc.Registry})
    start_supervised!({Egghead.Doc.Supervisor, []})
    start_supervised!({Egghead.RecordSupervisor, records_dir: tmp_dir, db_path: db_path})

    Process.sleep(300)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  defp create_fixture(tmp_dir, id, body) do
    path = Path.join(tmp_dir, "#{id}.md")
    File.write!(path, "---\ntitle: #{id}\nclass: durable\n---\n\n#{body}\n")
    Process.sleep(500)
    id
  end

  defp wait_for_convergence(clients, timeout \\ 3000) do
    # Wait for updates to propagate, then read all clients
    Process.sleep(timeout)
    Enum.map(clients, &YjsClient.read/1)
  end

  describe "two-client convergence" do
    test "both clients see the same content after concurrent edits", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "converge", "Hello")

      {:ok, c1} = YjsClient.start_link(id, self())
      {:ok, c2} = YjsClient.start_link(id, self())

      :ok = YjsClient.connect(c1)
      :ok = YjsClient.connect(c2)

      # Both start with "Hello"
      text = YjsClient.read(c1)
      assert String.trim(text) == "Hello"
      assert String.trim(YjsClient.read(c2)) == "Hello"

      # Client 1 appends " world" after "Hello"
      hello_end = :binary.match(text, "Hello") |> elem(0) |> Kernel.+(5)
      YjsClient.insert(c1, hello_end, " world")

      # Client 2 prepends "Oh! "
      YjsClient.insert(c2, 0, "Oh! ")

      # Wait for updates to propagate through the server
      [text1, text2] = wait_for_convergence([c1, c2])

      # Both must converge to the same content
      assert text1 == text2
      # Both edits must be present
      assert text1 =~ "Oh!"
      assert text1 =~ "world"
    end

    test "rapid alternating edits converge", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "rapid", "START")

      {:ok, c1} = YjsClient.start_link(id, self())
      {:ok, c2} = YjsClient.start_link(id, self())

      :ok = YjsClient.connect(c1)
      :ok = YjsClient.connect(c2)

      # Alternate rapid edits — all prepend at position 0
      for i <- 1..10 do
        if rem(i, 2) == 0 do
          YjsClient.insert(c1, 0, "a")
        else
          YjsClient.insert(c2, 0, "b")
        end
      end

      [text1, text2] = wait_for_convergence([c1, c2])

      # Both clients converge to identical content
      assert text1 == text2
      # Original content preserved, both clients contributed
      assert text1 =~ "START"
      a_count = text1 |> String.graphemes() |> Enum.count(&(&1 == "a"))
      b_count = text1 |> String.graphemes() |> Enum.count(&(&1 == "b"))
      assert a_count >= 5
      assert b_count >= 5
      # No edits lost
      assert a_count + b_count >= 10
    end

    test "delete + insert on overlapping range converges", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "overlap", "ABCDEF")

      {:ok, c1} = YjsClient.start_link(id, self())
      {:ok, c2} = YjsClient.start_link(id, self())

      :ok = YjsClient.connect(c1)
      :ok = YjsClient.connect(c2)

      # Client 1 deletes "CD" (bytes 2..4)
      YjsClient.delete(c1, 2, 2)

      # Client 2 inserts "XX" at position 3 (inside the range c1 deleted)
      YjsClient.insert(c2, 3, "XX")

      [text1, text2] = wait_for_convergence([c1, c2])

      assert text1 == text2
      # "XX" insert should survive (CRDT preserves inserts)
      assert text1 =~ "XX"
    end
  end

  describe "external file edit during live session" do
    test "file edit merges with in-flight client edits", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "external-merge", "Line one\nLine two\nLine three")

      {:ok, c1} = YjsClient.start_link(id, self())
      :ok = YjsClient.connect(c1)

      # Client adds text at the end
      body = YjsClient.read(c1)
      YjsClient.insert(c1, byte_size(body) - 1, "\nLine four")

      # External editor modifies the beginning
      path = Path.join(tmp_dir, "#{id}.md")

      File.write!(
        path,
        "---\ntitle: #{id}\nclass: durable\n---\n\nModified line one\nLine two\nLine three\n"
      )

      # Wait for watcher + reconciliation + propagation
      Process.sleep(4000)

      text = YjsClient.read(c1)

      # Both edits should be present
      assert text =~ "Modified line one"
      assert text =~ "Line four"
    end

    test "file edit with unicode merges correctly", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "unicode-merge", "Hello → World")

      {:ok, c1} = YjsClient.start_link(id, self())
      :ok = YjsClient.connect(c1)

      # External edit changes content with multi-byte chars
      path = Path.join(tmp_dir, "#{id}.md")

      File.write!(
        path,
        "---\ntitle: #{id}\nclass: durable\n---\n\nHello → Beautiful → World\n"
      )

      Process.sleep(4000)

      text = YjsClient.read(c1)
      assert text =~ "Hello → Beautiful → World"
    end
  end

  describe "disconnect and reconnect" do
    test "new client joining gets current state", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "late-join", "Original")

      {:ok, c1} = YjsClient.start_link(id, self())
      :ok = YjsClient.connect(c1)

      # Client 1 edits
      YjsClient.insert(c1, byte_size("Original"), " edited")
      Process.sleep(1000)

      # Client 2 joins later
      {:ok, c2} = YjsClient.start_link(id, self())
      :ok = YjsClient.connect(c2)

      Process.sleep(1000)

      # Client 2 should have the edited content
      text2 = YjsClient.read(c2)
      assert text2 =~ "Original edited"
    end

    test "client crash triggers cleanup via monitor", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "crash-cleanup", "Content")

      {:ok, pid} = Server.ensure_started(id)

      # Use start (not start_link) for the client we'll kill,
      # so killing it doesn't cascade to the test process
      {:ok, c1} = YjsClient.start(id, self())
      :ok = YjsClient.connect(c1)

      {:ok, c2} = YjsClient.start_link(id, self())
      :ok = YjsClient.connect(c2)

      # Kill client 1 abruptly
      Process.exit(c1, :kill)
      Process.sleep(500)

      # Server should still be alive (c2 is still connected)
      assert Process.alive?(pid)

      # Client 2 should still work
      YjsClient.insert(c2, 0, "Still works: ")
      Process.sleep(1000)

      text = YjsClient.read(c2)
      assert text =~ "Still works"
    end

    test "edits flush to disk before last client disconnects", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "flush-on-close", "Before")

      {:ok, c1} = YjsClient.start_link(id, self())
      :ok = YjsClient.connect(c1)

      YjsClient.insert(c1, byte_size("Before"), " after")

      # Detach — server should flush dirty buffer in terminate
      Server.detach(id, c1)
      Process.sleep(6000)

      # Read from disk — should have the edit
      {:ok, record} = Egghead.get_record(id)
      assert record.body =~ "after"
    end
  end

  describe "disk convergence" do
    test "all client edits eventually reach disk", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "disk-converge", "Start")

      {:ok, c1} = YjsClient.start_link(id, self())
      {:ok, c2} = YjsClient.start_link(id, self())

      :ok = YjsClient.connect(c1)
      :ok = YjsClient.connect(c2)

      YjsClient.insert(c1, byte_size("Start"), " from-c1")
      YjsClient.insert(c2, 0, "from-c2 ")

      # Wait for debounce + flush
      Process.sleep(4000)

      {:ok, record} = Egghead.get_record(id)
      assert record.body =~ "from-c1"
      assert record.body =~ "from-c2"

      # And both clients agree with disk
      [text1, text2] = wait_for_convergence([c1, c2], 1000)
      disk_body = record.body
      assert String.trim(text1) == String.trim(disk_body)
      assert String.trim(text2) == String.trim(disk_body)
    end
  end

  describe "agent CRDT editing" do
    test "agent_edit applies changes visible to connected client", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "agent-edit", "Original content")

      {:ok, c1} = YjsClient.start_link(id, self())
      :ok = YjsClient.connect(c1)

      assert String.trim(YjsClient.read(c1)) == "Original content"

      # Agent edits through the CRDT path
      :ok = Server.agent_edit(id, "agents/scout", "Modified by agent")

      Process.sleep(1000)

      text = YjsClient.read(c1)
      assert text =~ "Modified by agent"
    end

    test "agent_edit sends cursor events to client", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "agent-cursor", "Some text here")

      # Attach directly to receive raw messages
      {:ok, _pid} = Server.ensure_started(id)
      {:ok, _} = Server.attach(id, self())

      Server.agent_edit(id, "agents/scout", "Replaced text here")

      # Should receive agent cursor messages
      assert_receive {:doc_update, {:agent_cursor, %{agent_id: "agents/scout", active: true}}},
                     5000

      assert_receive {:doc_update, {:agent_cursor, %{agent_id: "agents/scout", active: false}}},
                     5000
    end

    test "agent_edit with no changes is a no-op", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "agent-noop", "Unchanged")

      {:ok, c1} = YjsClient.start_link(id, self())
      :ok = YjsClient.connect(c1)

      :ok = Server.agent_edit(id, "agents/scout", YjsClient.read(c1))

      # No update messages should arrive
      refute_receive {:client_updated, _}, 500
    end

    test "agent_edit while client is typing merges correctly", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "agent-merge", "Line one\nLine two\nLine three")

      {:ok, c1} = YjsClient.start_link(id, self())
      :ok = YjsClient.connect(c1)

      # Client edits beginning — wait for it to reach the server
      YjsClient.insert(c1, 0, "Prepended! ")
      Process.sleep(500)

      # Agent edits end (after client edit has been applied)
      current = "Prepended! Line one\nLine two\nLine three"
      new_body = current <> "\nLine four from agent"
      Server.agent_edit(id, "agents/scout", new_body)

      Process.sleep(2000)

      text = YjsClient.read(c1)
      assert text =~ "Prepended!"
      assert text =~ "Line four from agent"
    end

    test "alive?/1 returns false when no Doc.Server running" do
      refute Server.alive?("nonexistent-record")
    end

    test "alive?/1 returns true when Doc.Server running", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "alive-check", "Content")

      {:ok, _} = Server.ensure_started(id)
      {:ok, _} = Server.attach(id, self())

      assert Server.alive?(id)
    end

    test "fallback: update_record works when no Doc.Server", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "fallback", "Before")

      refute Server.alive?(id)

      {:ok, _} = Egghead.update_record(id, %{body: "After"})
      {:ok, record} = Egghead.get_record(id)
      assert record.body =~ "After"
    end
  end
end
