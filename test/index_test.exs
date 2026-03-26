defmodule Egghead.IndexTest do
  use ExUnit.Case

  alias Egghead.Index
  alias Egghead.Record

  defp start_index do
    name = :"index_#{:erlang.unique_integer([:positive])}"
    {:ok, _pid} = Index.start_link(db_path: ":memory:", name: name)
    name
  end

  defp make_record(attrs) do
    defaults = %{
      id: "rec_#{:erlang.unique_integer([:positive])}",
      title: "Test Record",
      created: "2026-03-25T10:00:00Z",
      updated: "2026-03-25T10:00:00Z",
      author: "mark",
      tags: [],
      links: [],
      wikilinks: [],
      class: :durable,
      body: "Test body content.",
      ast: nil,
      outline: [],
      format: :markdown,
      source_path: "/tmp/test/#{attrs[:id] || "rec"}.md"
    }

    struct!(Record, Map.merge(defaults, attrs))
  end

  describe "upsert and get" do
    test "upserts and retrieves a record" do
      idx = start_index()
      rec = make_record(%{id: "rec_001", title: "First", tags: ["arch"], links: ["rec_002"]})

      :ok = Index.upsert_record(idx, rec)
      assert {:ok, meta} = Index.get_record_meta(idx, "rec_001")
      assert meta.id == "rec_001"
      assert meta.title == "First"
      assert meta.tags == ["arch"]
      assert meta.links == ["rec_002"]
    end

    test "upsert replaces existing record" do
      idx = start_index()
      rec1 = make_record(%{id: "rec_001", title: "V1", tags: ["old"]})
      rec2 = make_record(%{id: "rec_001", title: "V2", tags: ["new"]})

      :ok = Index.upsert_record(idx, rec1)
      :ok = Index.upsert_record(idx, rec2)

      assert {:ok, meta} = Index.get_record_meta(idx, "rec_001")
      assert meta.title == "V2"
      assert meta.tags == ["new"]
    end

    test "get_record_meta returns error for missing id" do
      idx = start_index()
      assert {:error, :not_found} = Index.get_record_meta(idx, "nonexistent")
    end
  end

  describe "list_records" do
    test "returns all records" do
      idx = start_index()
      Index.upsert_record(idx, make_record(%{id: "a"}))
      Index.upsert_record(idx, make_record(%{id: "b"}))
      Index.upsert_record(idx, make_record(%{id: "c"}))

      records = Index.list_records(idx)
      ids = Enum.map(records, & &1.id) |> Enum.sort()
      assert ids == ["a", "b", "c"]
    end

    test "returns Record structs with nil body and ast" do
      idx = start_index()
      Index.upsert_record(idx, make_record(%{id: "rec_001"}))

      [rec] = Index.list_records(idx)
      assert %Record{} = rec
      assert rec.body == nil
      assert rec.ast == nil
    end
  end

  describe "search_by_tag" do
    test "finds records by tag" do
      idx = start_index()
      Index.upsert_record(idx, make_record(%{id: "a", tags: ["arch", "elixir"]}))
      Index.upsert_record(idx, make_record(%{id: "b", tags: ["elixir"]}))
      Index.upsert_record(idx, make_record(%{id: "c", tags: ["other"]}))

      results = Index.search_by_tag(idx, "elixir")
      ids = Enum.map(results, & &1.id) |> Enum.sort()
      assert ids == ["a", "b"]

      assert Index.search_by_tag(idx, "nonexistent") == []
    end
  end

  describe "search_by_class" do
    test "filters by class" do
      idx = start_index()
      Index.upsert_record(idx, make_record(%{id: "d", class: :durable}))
      Index.upsert_record(idx, make_record(%{id: "i", class: :inbox}))
      Index.upsert_record(idx, make_record(%{id: "x", class: :deliberation}))

      assert [%{id: "d"}] = Index.search_by_class(idx, :durable)
      assert [%{id: "i"}] = Index.search_by_class(idx, :inbox)
      assert [%{id: "x"}] = Index.search_by_class(idx, :deliberation)
    end
  end

  describe "find_links" do
    test "traverses one level" do
      idx = start_index()
      Index.upsert_record(idx, make_record(%{id: "a", links: ["b", "c"]}))
      Index.upsert_record(idx, make_record(%{id: "b", links: ["c"]}))
      Index.upsert_record(idx, make_record(%{id: "c"}))

      results = Index.find_links(idx, "a", 1)
      ids = Enum.map(results, & &1.id) |> Enum.sort()
      assert ids == ["b", "c"]
    end

    test "traverses multiple levels" do
      idx = start_index()
      Index.upsert_record(idx, make_record(%{id: "a", links: ["b"]}))
      Index.upsert_record(idx, make_record(%{id: "b", links: ["c"]}))
      Index.upsert_record(idx, make_record(%{id: "c"}))

      results = Index.find_links(idx, "a", 2)
      ids = Enum.map(results, & &1.id) |> Enum.sort()
      assert ids == ["b", "c"]
    end

    test "returns empty for no links" do
      idx = start_index()
      Index.upsert_record(idx, make_record(%{id: "lonely"}))
      assert Index.find_links(idx, "lonely", 1) == []
    end

    test "returns empty for nonexistent record" do
      idx = start_index()
      assert Index.find_links(idx, "nope", 1) == []
    end
  end

  describe "find_backlinks" do
    test "finds records that link TO a given id" do
      idx = start_index()
      Index.upsert_record(idx, make_record(%{id: "a", links: ["target"]}))
      Index.upsert_record(idx, make_record(%{id: "b", links: ["target"]}))
      Index.upsert_record(idx, make_record(%{id: "c", links: ["other"]}))
      Index.upsert_record(idx, make_record(%{id: "target"}))

      results = Index.find_backlinks(idx, "target")
      ids = Enum.map(results, & &1.id) |> Enum.sort()
      assert ids == ["a", "b"]
    end

    test "returns empty when nothing links to the record" do
      idx = start_index()
      Index.upsert_record(idx, make_record(%{id: "island"}))
      assert Index.find_backlinks(idx, "island") == []
    end
  end

  describe "full-text search" do
    test "finds records by body content" do
      idx = start_index()

      Index.upsert_record(
        idx,
        make_record(%{
          id: "a",
          title: "Error Handling",
          body: "When the API returns a 422 error, retry with backoff."
        })
      )

      Index.upsert_record(
        idx,
        make_record(%{
          id: "b",
          title: "Architecture",
          body: "Service boundaries and message passing."
        })
      )

      results = Index.search(idx, "error")
      ids = Enum.map(results, & &1.id)
      assert "a" in ids
    end

    test "finds records by title" do
      idx = start_index()
      Index.upsert_record(idx, make_record(%{id: "a", title: "Error Handling", body: "Content."}))
      Index.upsert_record(idx, make_record(%{id: "b", title: "Architecture", body: "Other."}))

      results = Index.search(idx, "architecture")
      assert [%{id: "b"}] = results
    end

    test "returns empty for no matches" do
      idx = start_index()
      Index.upsert_record(idx, make_record(%{id: "a", body: "hello"}))
      assert Index.search(idx, "zzzznotfound") == []
    end

    test "respects limit" do
      idx = start_index()

      for i <- 1..10 do
        Index.upsert_record(idx, make_record(%{id: "r#{i}", body: "common search term here"}))
      end

      results = Index.search(idx, "common", limit: 3)
      assert length(results) == 3
    end
  end

  describe "recent" do
    test "returns records ordered by updated" do
      idx = start_index()
      Index.upsert_record(idx, make_record(%{id: "old", updated: "2026-01-01T00:00:00Z"}))
      Index.upsert_record(idx, make_record(%{id: "new", updated: "2026-03-25T12:00:00Z"}))
      Index.upsert_record(idx, make_record(%{id: "mid", updated: "2026-02-15T00:00:00Z"}))

      results = Index.recent(idx)
      ids = Enum.map(results, & &1.id)
      assert ids == ["new", "mid", "old"]
    end

    test "filters by since" do
      idx = start_index()
      Index.upsert_record(idx, make_record(%{id: "old", updated: "2026-01-01T00:00:00Z"}))
      Index.upsert_record(idx, make_record(%{id: "new", updated: "2026-03-25T12:00:00Z"}))

      results = Index.recent(idx, since: "2026-03-01")
      assert [%{id: "new"}] = results
    end

    test "respects limit" do
      idx = start_index()

      for i <- 1..10 do
        Index.upsert_record(
          idx,
          make_record(%{
            id: "r#{i}",
            updated: "2026-03-#{String.pad_leading("#{i}", 2, "0")}T00:00:00Z"
          })
        )
      end

      results = Index.recent(idx, limit: 3)
      assert length(results) == 3
    end

    test "can order by created" do
      idx = start_index()

      Index.upsert_record(
        idx,
        make_record(%{id: "a", created: "2026-03-25T00:00:00Z", updated: "2026-01-01T00:00:00Z"})
      )

      Index.upsert_record(
        idx,
        make_record(%{id: "b", created: "2026-01-01T00:00:00Z", updated: "2026-03-25T00:00:00Z"})
      )

      by_created = Index.recent(idx, order_by: :created)
      assert [%{id: "a"}, %{id: "b"}] = by_created

      by_updated = Index.recent(idx, order_by: :updated)
      assert [%{id: "b"}, %{id: "a"}] = by_updated
    end
  end

  describe "delete" do
    test "removes record by source path" do
      idx = start_index()
      rec = make_record(%{id: "doomed", tags: ["tag"], links: ["other"]})
      Index.upsert_record(idx, rec)

      assert {:ok, _} = Index.get_record_meta(idx, "doomed")

      :ok = Index.delete_by_path(idx, rec.source_path)

      assert {:error, :not_found} = Index.get_record_meta(idx, "doomed")
      assert Index.search_by_tag(idx, "tag") == []
    end
  end

  describe "id change" do
    test "upsert with changed id removes old entry for same source_path" do
      idx = start_index()
      path = "/tmp/test/changeable.md"

      # First version with id "old_id"
      rec1 = make_record(%{id: "old_id", title: "Original", source_path: path})
      Index.upsert_record(idx, rec1)
      assert {:ok, _} = Index.get_record_meta(idx, "old_id")

      # User edits the id in frontmatter — same file, new id
      rec2 = make_record(%{id: "new_id", title: "Renamed", source_path: path})
      Index.upsert_record(idx, rec2)

      # Old id is gone, new id is present
      assert {:error, :not_found} = Index.get_record_meta(idx, "old_id")
      assert {:ok, meta} = Index.get_record_meta(idx, "new_id")
      assert meta.title == "Renamed"
    end
  end

  describe "rebuild" do
    test "rebuilds from a directory of files" do
      dir = Path.join(System.tmp_dir!(), "idx_rebuild_#{:erlang.unique_integer([:positive])}")
      File.rm_rf!(dir)
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "rec_001.md"), """
      ---
      id: rec_001
      tags: [test]
      ---

      # First Record

      Body of the first record.
      """)

      File.write!(Path.join(dir, "rec_002.md"), """
      ---
      id: rec_002
      links: [rec_001]
      ---

      # Second Record

      Links to [[rec_001]].
      """)

      idx = start_index()
      :ok = Index.rebuild(idx, dir)

      records = Index.list_records(idx)
      assert length(records) == 2

      assert [%{id: "rec_001"}] = Index.search_by_tag(idx, "test")
      assert [%{id: "rec_002"}] = Index.find_backlinks(idx, "rec_001")
      assert [%{id: "rec_001"}] = Index.find_links(idx, "rec_002", 1)
    end
  end

  describe "wikilinks" do
    test "stores and retrieves wikilink metadata" do
      idx = start_index()

      rec =
        make_record(%{
          id: "a",
          wikilinks: [
            %{target: "b", display: "the B note", fragment: nil},
            %{target: "c", display: nil, fragment: "section"}
          ]
        })

      Index.upsert_record(idx, rec)
      {:ok, meta} = Index.get_record_meta(idx, "a")

      assert length(meta.wikilinks) == 2
      assert %{target: "b", display: "the B note", fragment: nil} in meta.wikilinks
      assert %{target: "c", display: nil, fragment: "section"} in meta.wikilinks
    end
  end
end
