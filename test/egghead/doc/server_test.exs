defmodule Egghead.Doc.ServerTest do
  use ExUnit.Case, async: false

  alias Egghead.Doc.Server

  @moduletag :records

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "egghead_doc_test_#{:erlang.unique_integer([:positive])}")

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

    content =
      "---\ntitle: #{String.capitalize(id)}\nclass: durable\n---\n\n#{body}\n"

    File.write!(path, content)
    Process.sleep(500)
    id
  end

  describe "seeding" do
    test "seeds Y.Text from record body", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "seed-test", "Hello, world!")

      {:ok, _pid} = Server.ensure_started(id)
      {:ok, state_update} = Server.get_state(id)

      assert is_binary(state_update)
      assert byte_size(state_update) > 0
    end

    test "stops if record does not exist" do
      result = Server.ensure_started("nonexistent-record")
      assert {:ok, pid} = result

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :record_not_found}}, 1000
    end
  end

  describe "attach/detach lifecycle" do
    test "returns initial state on attach", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "attach-test", "Content here")

      {:ok, _pid} = Server.ensure_started(id)
      {:ok, update} = Server.attach(id, self())

      assert is_binary(update)
    end

    test "shuts down after last client detaches", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "shutdown-test", "Will shut down")

      {:ok, pid} = Server.ensure_started(id)
      {:ok, _} = Server.attach(id, self())

      ref = Process.monitor(pid)
      Server.detach(id, self())

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
    end

    test "cancels shutdown when new client attaches", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "cancel-test", "Stay alive")

      {:ok, pid} = Server.ensure_started(id)
      {:ok, _} = Server.attach(id, self())
      Server.detach(id, self())

      Process.sleep(100)
      {:ok, _} = Server.attach(id, self())

      Process.sleep(6000)
      assert Process.alive?(pid)

      Server.detach(id, self())
    end
  end

  describe "client updates" do
    test "broadcasts updates to attached clients", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "broadcast-test", "Original")

      {:ok, _pid} = Server.ensure_started(id)
      {:ok, _} = Server.attach(id, self())

      doc = Yex.Doc.new()
      text = Yex.Doc.get_text(doc, "content")
      Yex.Text.insert(text, 0, "Original modified")
      {:ok, update} = Yex.encode_state_as_update(doc)

      Server.apply_update(id, update)

      assert_receive {:doc_update, {:yjs_update, _update}}, 2000
    end
  end

  describe "debounce and flush" do
    test "flushes edits to disk after debounce", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "flush-test", "Before edit")

      {:ok, _pid} = Server.ensure_started(id)
      {:ok, _} = Server.attach(id, self())

      doc = Yex.Doc.new()
      text = Yex.Doc.get_text(doc, "content")
      Yex.Text.insert(text, 0, "After edit")
      {:ok, update} = Yex.encode_state_as_update(doc)

      Server.apply_update(id, update)

      Process.sleep(3000)

      {:ok, record} = Egghead.get_record(id)
      assert record.body =~ "After edit"
    end
  end

  describe "external change reconciliation" do
    test "reconciles file changes into Y.Doc", %{tmp_dir: tmp_dir} do
      id = create_fixture(tmp_dir, "reconcile-test", "Original content")

      {:ok, _pid} = Server.ensure_started(id)
      {:ok, _} = Server.attach(id, self())

      path = Path.join(tmp_dir, "#{id}.md")

      new_content =
        "---\ntitle: Reconcile-test\nclass: durable\n---\n\nModified externally\n"

      File.write!(path, new_content)

      assert_receive {:doc_update, {:yjs_update, _update}}, 5000
    end
  end
end
