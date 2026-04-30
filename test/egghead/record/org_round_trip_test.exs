defmodule Egghead.Record.OrgRoundTripTest do
  @moduledoc """
  End-to-end round-trip tests for org-mode records through the RecordStore.

  These exercise the full path: create → write to disk → reparse → update →
  re-read. The invariant being tested is **byte-stability of unrelated
  content**: editing one field of an org record must not perturb anything
  else on disk.
  """

  use ExUnit.Case, async: false

  alias Egghead.Index
  alias Egghead.RecordStore

  setup context do
    dir =
      Path.join(
        System.tmp_dir!(),
        "egghead_org_rt_#{context.test |> to_string() |> :erlang.phash2()}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    suffix = :erlang.unique_integer([:positive])
    idx_name = :"index_#{suffix}"
    store_name = :"store_#{suffix}"

    {:ok, _} = Index.start_link(db_path: ":memory:", name: idx_name)

    {:ok, _} =
      RecordStore.start_link(
        records_dir: dir,
        name: store_name,
        watch: false,
        index: idx_name
      )

    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir, store: store_name}
  end

  describe "create_record with format: :org" do
    test "writes a .org file", %{dir: dir, store: store} do
      assert {:ok, record} =
               RecordStore.create_record(store, %{
                 id: "rec_1",
                 title: "Hello",
                 format: :org,
                 body: "Some content."
               })

      assert record.format == :org
      assert File.exists?(Path.join(dir, "rec_1.org"))
      refute File.exists?(Path.join(dir, "rec_1.md"))
    end

    test "accepts \"org\" string format", %{dir: dir, store: store} do
      assert {:ok, _} =
               RecordStore.create_record(store, %{
                 "id" => "rec_2",
                 "title" => "T",
                 "format" => "org"
               })

      assert File.exists?(Path.join(dir, "rec_2.org"))
    end

    test "default is markdown when no format given", %{dir: dir, store: store} do
      assert {:ok, _} = RecordStore.create_record(store, %{id: "rec_3", title: "T"})
      assert File.exists?(Path.join(dir, "rec_3.md"))
    end

    test "the written file parses back into the same record", %{store: store} do
      attrs = %{
        id: "rec_rt",
        title: "Round Trip",
        author: "mark",
        tags: ["a", "b"],
        links: ["rec_other"],
        class: "durable",
        format: :org,
        body: "Body content."
      }

      assert {:ok, created} = RecordStore.create_record(store, attrs)
      assert {:ok, fetched} = RecordStore.get_record(store, "rec_rt")

      assert fetched.id == created.id
      assert fetched.title == "Round Trip"
      assert fetched.author == "mark"
      assert fetched.tags == ["a", "b"]
      assert fetched.links == ["rec_other"]
      assert fetched.class == :durable
      assert fetched.format == :org
    end
  end

  describe "update_record on org records preserves format and unrelated bytes" do
    test "body-only update keeps the file as .org", %{dir: dir, store: store} do
      {:ok, _} =
        RecordStore.create_record(store, %{
          id: "rec_body",
          title: "T",
          format: :org,
          body: "Old body."
        })

      assert {:ok, _} = RecordStore.update_record(store, "rec_body", %{body: "New body."})

      content = File.read!(Path.join(dir, "rec_body.org"))
      assert content =~ "New body."
      refute content =~ "Old body."
    end

    test "title update splices in place; body and other fields untouched on disk",
         %{dir: dir, store: store} do
      {:ok, _} =
        RecordStore.create_record(store, %{
          id: "rec_title",
          title: "Original",
          author: "mark",
          tags: ["x"],
          format: :org,
          body: "Don't touch this body."
        })

      original = File.read!(Path.join(dir, "rec_title.org"))

      assert {:ok, updated} =
               RecordStore.update_record(store, "rec_title", %{title: "Renamed"})

      after_content = File.read!(Path.join(dir, "rec_title.org"))

      # Title swapped.
      assert after_content =~ "#+TITLE: Renamed"
      refute after_content =~ "#+TITLE: Original"

      # Author + tags + body line-for-line preserved.
      assert after_content =~ "#+AUTHOR: mark"
      assert after_content =~ "#+FILETAGS: :x:"
      assert after_content =~ "Don't touch this body."

      # Diff is exactly one line of difference (the title line).
      diff_count = line_diff_count(original, after_content)
      assert diff_count == 1
      assert updated.title == "Renamed"
    end

    test "tag update preserves user's existing keyword casing", %{dir: dir, store: store} do
      raw = """
      #+title: My Doc
      #+filetags: :old:

      Body.
      """

      path = Path.join(dir, "rec_case.org")
      File.write!(path, raw)
      Index.rebuild(store_index(store), dir)

      {:ok, _} = RecordStore.update_record(store, "rec_case", %{tags: ["new"]})

      after_content = File.read!(path)
      # Lower-case keywords stay lower-case; only the value changes.
      assert after_content =~ "#+title: My Doc"
      assert after_content =~ "#+filetags: :new:"
    end

    test "body-only update with the full file content is byte-stable",
         %{dir: dir, store: store} do
      {:ok, _} =
        RecordStore.create_record(store, %{
          id: "rec_stable",
          title: "T",
          format: :org,
          body: "Some content."
        })

      path = Path.join(dir, "rec_stable.org")
      original = File.read!(path)

      # For org records, `body` is the full file content. A body-only update
      # with the same content should leave the file byte-identical.
      {:ok, _} =
        RecordStore.update_record(store, "rec_stable", %{
          body: String.trim_trailing(original)
        })

      after_content = File.read!(path)
      assert after_content == original
    end
  end

  describe "create_record reads stored format on get" do
    test "format field flows through index and hydrate", %{store: store} do
      {:ok, _} =
        RecordStore.create_record(store, %{id: "rec_fmt", title: "T", format: :org})

      {:ok, fetched} = RecordStore.get_record(store, "rec_fmt")
      assert fetched.format == :org

      {:ok, _} =
        RecordStore.create_record(store, %{id: "rec_md", title: "T", format: :markdown})

      {:ok, fetched_md} = RecordStore.get_record(store, "rec_md")
      assert fetched_md.format == :markdown
    end
  end

  describe "default_format application env" do
    setup do
      original = Application.get_env(:egghead, :default_format, :markdown)
      on_exit(fn -> Application.put_env(:egghead, :default_format, original) end)
      :ok
    end

    test "create_record without format honors :default_format = :org", %{
      dir: dir,
      store: store
    } do
      Application.put_env(:egghead, :default_format, :org)

      {:ok, _} = RecordStore.create_record(store, %{id: "rec_def", title: "T"})

      assert File.exists?(Path.join(dir, "rec_def.org"))
    end
  end

  # --- Helpers ---

  defp line_diff_count(a, b) do
    a_lines = String.split(a, "\n")
    b_lines = String.split(b, "\n")

    a_lines
    |> Enum.zip(b_lines)
    |> Enum.count(fn {x, y} -> x != y end)
    |> Kernel.+(abs(length(a_lines) - length(b_lines)))
  end

  # The store_name we register the genserver under doesn't directly map to the
  # index name. Pull the store's state to get its index ref.
  defp store_index(store) do
    state = :sys.get_state(Process.whereis(store))
    state.index
  end
end
