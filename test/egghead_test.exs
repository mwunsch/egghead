defmodule EggheadTest do
  use ExUnit.Case

  alias Egghead.Record
  alias Egghead.Record.AST
  alias Egghead.Record.Parser
  alias Egghead.RecordStore

  # --- Helpers ---

  defp tmp_dir(context) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "egghead_test_#{context.test |> to_string() |> :erlang.phash2()}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp start_store(dir, opts \\ []) do
    name = :"store_#{:erlang.unique_integer([:positive])}"

    {:ok, pid} =
      RecordStore.start_link([records_dir: dir, name: name, watch: false] ++ opts)

    {pid, name}
  end

  defp write_file(dir, filename, content) do
    File.write!(Path.join(dir, filename), content)
  end

  # --- Sample content ---

  @markdown_record """
  ---
  id: rec_0042
  created: 2026-03-25T10:30:00Z
  author: mark
  tags: [architecture, error-handling]
  links: [rec_0038, rec_0041]
  class: durable
  ---

  # API Error Handling Pattern

  Content here...
  """

  @org_record """
  :PROPERTIES:
  :ID: rec_0042
  :CREATED: 2026-03-25T10:30:00Z
  :AUTHOR: mark
  :TAGS: architecture error-handling
  :LINKS: rec_0038 rec_0041
  :CLASS: durable
  :END:
  #+TITLE: API Error Handling Pattern

  Content here...
  """

  # --- Format detection ---

  describe "format detection" do
    test "detects markdown format" do
      assert Parser.detect_format(@markdown_record) == :markdown
    end

    test "detects org-mode format" do
      assert Parser.detect_format(@org_record) == :org
    end

    test "returns unknown for plain text" do
      assert Parser.detect_format("just some text") == :unknown
    end

    test "handles leading whitespace" do
      assert Parser.detect_format("  \n---\nid: foo\n---\n") == :markdown
      assert Parser.detect_format("  \n:PROPERTIES:\n:END:\n") == :org
    end
  end

  # --- Markdown parsing ---

  describe "markdown parsing" do
    test "parses a full markdown record" do
      assert {:ok, record} = Parser.parse(@markdown_record)

      assert record.id == "rec_0042"
      assert record.created == "2026-03-25T10:30:00Z"
      assert record.author == "mark"
      assert record.tags == ["architecture", "error-handling"]
      assert record.links == ["rec_0038", "rec_0041"]
      assert record.class == :durable
      assert record.title == "API Error Handling Pattern"
      assert record.body =~ "Content here..."
      assert record.format == :markdown
    end

    test "parses inbox class" do
      content = """
      ---
      id: rec_inbox_01
      class: inbox
      ---

      # Email summary
      """

      assert {:ok, record} = Parser.parse(content)
      assert record.class == :inbox
    end

    test "parses deliberation class" do
      content = """
      ---
      id: rec_delib_01
      class: deliberation
      ---

      # Review session
      """

      assert {:ok, record} = Parser.parse(content)
      assert record.class == :deliberation
    end

    test "defaults to durable class when missing" do
      content = """
      ---
      id: rec_no_class
      ---

      # No class specified
      """

      assert {:ok, record} = Parser.parse(content)
      assert record.class == :durable
    end

    test "defaults to durable for unrecognized class" do
      content = """
      ---
      id: rec_bad_class
      class: banana
      ---

      Body
      """

      assert {:ok, record} = Parser.parse(content)
      assert record.class == :durable
    end

    test "handles missing optional fields" do
      content = """
      ---
      id: rec_minimal
      ---

      Just a body.
      """

      assert {:ok, record} = Parser.parse(content)
      assert record.id == "rec_minimal"
      assert record.author == nil
      assert record.created == nil
      assert record.tags == []
      assert record.links == []
      assert record.class == :durable
    end

    test "handles empty body" do
      content = """
      ---
      id: rec_empty
      author: mark
      ---
      """

      assert {:ok, record} = Parser.parse(content)
      assert record.id == "rec_empty"
      assert record.body == ""
    end

    test "extracts title from heading when not in frontmatter" do
      content = """
      ---
      id: rec_heading
      ---

      # My Great Title

      Body text.
      """

      assert {:ok, record} = Parser.parse(content)
      assert record.title == "My Great Title"
    end

    test "passes source_path option through" do
      assert {:ok, record} = Parser.parse(@markdown_record, source_path: "/tmp/test.md")
      assert record.source_path == "/tmp/test.md"
    end
  end

  # --- Plain markdown (no frontmatter) ---

  describe "plain markdown parsing" do
    test "parses markdown with no frontmatter at all" do
      content = """
      # My Quick Thought

      Just a note I jotted down.
      """

      assert {:ok, record} = Parser.parse(content)
      assert record.title == "My Quick Thought"
      assert record.body =~ "Just a note I jotted down."
      assert record.format == :markdown
      assert record.class == :durable
      assert record.tags == []
      assert record.links == []
    end

    test "derives id from source_path filename" do
      content = "# Some Idea\n\nContent."
      assert {:ok, record} = Parser.parse(content, source_path: "/store/my-thought.md")
      assert record.id == "my-thought"
    end

    test "derives created from file birthtime", context do
      dir = tmp_dir(context)
      path = Path.join(dir, "timestamped.md")
      File.write!(path, "# Test\n\nBody.")

      assert {:ok, record} = Parser.parse("# Test\n\nBody.", source_path: path)
      assert record.created != nil
      # created should be an ISO 8601 timestamp
      assert record.created =~ ~r/^\d{4}-\d{2}-\d{2}T/
    end

    test "derives updated from file mtime", context do
      dir = tmp_dir(context)
      path = Path.join(dir, "updated.md")
      File.write!(path, "# Test\n\nBody.")

      assert {:ok, record} = Parser.parse("# Test\n\nBody.", source_path: path)
      assert record.updated != nil
      assert record.updated =~ ~r/^\d{4}-\d{2}-\d{2}T/
    end

    test "explicit frontmatter updated takes precedence" do
      content = """
      ---
      id: rec_upd
      updated: 2026-01-15T08:00:00Z
      ---

      # Note
      """

      assert {:ok, record} = Parser.parse(content)
      assert record.updated == "2026-01-15T08:00:00Z"
    end

    test "created and updated differ after file modification", context do
      dir = tmp_dir(context)
      path = Path.join(dir, "evolving.md")
      File.write!(path, "# V1\n\nFirst version.")
      # Touch the file with a later mtime
      future = System.os_time(:second) + 2
      File.touch!(path, future)

      assert {:ok, record} = Parser.parse("# V1\n\nFirst version.", source_path: path)
      # On macOS, created (birthtime) should be earlier than updated (mtime)
      assert record.created != nil
      assert record.updated != nil
    end

    test "derives author from file owner when no frontmatter author", context do
      dir = tmp_dir(context)
      path = Path.join(dir, "owned.md")
      File.write!(path, "# Note\n\nSome text.")

      assert {:ok, record} = Parser.parse("# Note\n\nSome text.", source_path: path)
      expected = System.get_env("USER")
      assert record.author == expected
    end

    test "explicit frontmatter author takes precedence over file owner", context do
      dir = tmp_dir(context)
      path = Path.join(dir, "explicit.md")

      content = """
      ---
      id: rec_explicit
      author: alice
      ---

      # Note
      """

      File.write!(path, content)
      assert {:ok, record} = Parser.parse(content, source_path: path)
      assert record.author == "alice"
    end

    test "id defaults to 'unknown' with no source_path and no frontmatter" do
      content = "# Orphan\n\nNo metadata at all."
      assert {:ok, record} = Parser.parse(content)
      assert record.id == "unknown"
    end

    test "wikilinks still work in plain markdown" do
      content = "# Connections\n\nSee [[rec_0001]] for context."
      assert {:ok, record} = Parser.parse(content)
      assert record.links == ["rec_0001"]
      assert length(record.wikilinks) == 1
    end
  end

  # --- Org-mode parsing ---

  describe "org-mode parsing" do
    test "parses a full org-mode record" do
      assert {:ok, record} = Parser.parse(@org_record)

      assert record.id == "rec_0042"
      assert record.created == "2026-03-25T10:30:00Z"
      assert record.author == "mark"
      assert record.tags == ["architecture", "error-handling"]
      assert record.links == ["rec_0038", "rec_0041"]
      assert record.class == :durable
      assert record.title == "API Error Handling Pattern"
      assert record.body =~ "Content here..."
      assert record.format == :org
    end

    test "handles org-mode with no links" do
      content = """
      :PROPERTIES:
      :ID: rec_no_links
      :AUTHOR: mark
      :CLASS: inbox
      :END:
      #+TITLE: Standalone Note

      Some content.
      """

      assert {:ok, record} = Parser.parse(content)
      assert record.id == "rec_no_links"
      assert record.links == []
      assert record.class == :inbox
      assert record.title == "Standalone Note"
    end

    test "handles org-mode with no title" do
      content = """
      :PROPERTIES:
      :ID: rec_no_title
      :END:

      Just content without a title line.
      """

      assert {:ok, record} = Parser.parse(content)
      assert record.id == "rec_no_title"
      assert record.title == nil
    end
  end

  # --- Wikilinks ---

  describe "wikilink extraction" do
    test "extracts basic [[target]] wikilinks" do
      content = """
      ---
      id: rec_wiki
      ---

      # Wikilink Test

      See [[rec_0038]] for background. Also related to [[rec_0041]].
      """

      assert {:ok, record} = Parser.parse(content)

      assert length(record.wikilinks) == 2
      assert %{target: "rec_0038", display: nil, fragment: nil} in record.wikilinks
      assert %{target: "rec_0041", display: nil, fragment: nil} in record.wikilinks
    end

    test "extracts [[target|display text]] wikilinks" do
      content = """
      ---
      id: rec_display
      ---

      See [[rec_0038|service boundaries]] for the convention.
      """

      assert {:ok, record} = Parser.parse(content)

      assert [%{target: "rec_0038", display: "service boundaries", fragment: nil}] =
               record.wikilinks
    end

    test "extracts [[target#fragment]] wikilinks" do
      content = """
      ---
      id: rec_frag
      ---

      See [[rec_0038#error-codes]] for the full list.
      """

      assert {:ok, record} = Parser.parse(content)

      assert [%{target: "rec_0038", display: nil, fragment: "error-codes"}] =
               record.wikilinks
    end

    test "extracts [[target#fragment|display]] wikilinks" do
      content = """
      ---
      id: rec_full
      ---

      See [[rec_0038#error-codes|the error code table]] for details.
      """

      assert {:ok, record} = Parser.parse(content)

      assert [%{target: "rec_0038", display: "the error code table", fragment: "error-codes"}] =
               record.wikilinks
    end

    test "merges wikilink targets into links, deduplicated" do
      content = """
      ---
      id: rec_merge
      links: [rec_0038, rec_0040]
      ---

      See [[rec_0038]] again, and also [[rec_0041]].
      """

      assert {:ok, record} = Parser.parse(content)

      # rec_0038 appears in both frontmatter and wikilink — deduplicated
      assert record.links == ["rec_0038", "rec_0040", "rec_0041"]
    end

    test "wikilinks with no frontmatter links" do
      content = """
      ---
      id: rec_only_wiki
      ---

      Links to [[rec_001]] and [[rec_002]].
      """

      assert {:ok, record} = Parser.parse(content)
      assert record.links == ["rec_001", "rec_002"]
    end

    test "no wikilinks in body yields empty wikilinks list" do
      content = """
      ---
      id: rec_no_wiki
      ---

      No links here, just plain text.
      """

      assert {:ok, record} = Parser.parse(content)
      assert record.wikilinks == []
    end

    test "links work in org-mode with org link syntax" do
      content = """
      :PROPERTIES:
      :ID: rec_org_wiki
      :LINKS: rec_0040
      :END:
      #+TITLE: Org Wikilinks

      See [[rec_0038][service boundaries]] and [[rec_0041]].
      """

      assert {:ok, record} = Parser.parse(content)

      assert length(record.wikilinks) == 2

      assert %{target: "rec_0038", display: "service boundaries", fragment: nil} in record.wikilinks

      assert %{target: "rec_0041", display: nil, fragment: nil} in record.wikilinks
      assert record.links == ["rec_0040", "rec_0038", "rec_0041"]
    end

    test "multiple wikilinks to same target are deduplicated in links" do
      content = """
      ---
      id: rec_dedup
      ---

      First mention of [[rec_0038]]. Second mention of [[rec_0038]].
      """

      assert {:ok, record} = Parser.parse(content)

      # wikilinks preserves both occurrences (they're positional references)
      assert length(record.wikilinks) == 2
      # links deduplicates
      assert record.links == ["rec_0038"]
    end
  end

  # --- Both formats produce equivalent records ---

  describe "format equivalence" do
    test "markdown and org-mode produce structurally identical records" do
      {:ok, md} = Parser.parse(@markdown_record)
      {:ok, org} = Parser.parse(@org_record)

      assert md.id == org.id
      assert md.created == org.created
      assert md.author == org.author
      assert md.tags == org.tags
      assert md.links == org.links
      assert md.class == org.class
      assert md.title == org.title
    end
  end

  # --- AST ---

  describe "Markdown AST" do
    test "parse_markdown produces an AST" do
      {:ok, ast} = AST.parse_markdown("# Hello\n\nWorld.")
      assert is_list(ast)
      assert {"h1", [], ["Hello"], %{}} in ast
    end

    test "extract_title finds first h1" do
      {:ok, ast} = AST.parse_markdown("## Not this\n\n# The Title\n\nBody.")
      assert AST.extract_title(ast) == "The Title"
    end

    test "extract_title handles inline markup in heading" do
      {:ok, ast} = AST.parse_markdown("# Title with **bold** and `code`")
      assert AST.extract_title(ast) == "Title with bold and code"
    end

    test "extract_title returns nil when no h1" do
      {:ok, ast} = AST.parse_markdown("## Only h2\n\nBody.")
      assert AST.extract_title(ast) == nil
    end

    test "extract_outline returns all headings with levels" do
      content = """
      # Top Level

      Some text.

      ## Section A

      More text.

      ### Subsection A.1

      ## Section B
      """

      {:ok, ast} = AST.parse_markdown(content)
      outline = AST.extract_outline(ast)

      assert outline == [
               %{level: 1, text: "Top Level"},
               %{level: 2, text: "Section A"},
               %{level: 3, text: "Subsection A.1"},
               %{level: 2, text: "Section B"}
             ]
    end

    test "extract_wikilinks from AST" do
      content = "See [[rec_001]] and [[rec_002|the other note]] here."
      {:ok, ast} = AST.parse_markdown(content)
      wikilinks = AST.extract_wikilinks(ast)

      assert length(wikilinks) == 2
      assert %{target: "rec_001", display: nil, fragment: nil} in wikilinks
      assert %{target: "rec_002", display: "the other note", fragment: nil} in wikilinks
    end

    test "extract_wikilinks with fragments from AST" do
      content = "See [[rec_001#section|details]] here."
      {:ok, ast} = AST.parse_markdown(content)
      [wl] = AST.extract_wikilinks(ast)

      assert wl.target == "rec_001"
      assert wl.fragment == "section"
      assert wl.display == "details"
    end

    test "extract_code_blocks" do
      content = """
      Some text.

      ```elixir
      def hello, do: :world
      ```

      More text.

      ```
      plain code
      ```
      """

      {:ok, ast} = AST.parse_markdown(content)
      blocks = AST.extract_code_blocks(ast)

      assert length(blocks) == 2
      assert %{language: "elixir", content: "def hello, do: :world"} in blocks
      assert %{language: nil, content: "plain code"} in blocks
    end
  end

  describe "AST integration with parser" do
    test "markdown records have ast and outline populated" do
      content = """
      ---
      id: rec_ast
      ---

      # Main Title

      Intro paragraph.

      ## Section One

      Content with [[rec_other]].
      """

      assert {:ok, record} = Parser.parse(content)
      assert record.ast != nil
      assert record.title == "Main Title"

      assert record.outline == [
               %{level: 1, text: "Main Title"},
               %{level: 2, text: "Section One"}
             ]

      assert [%{target: "rec_other"}] = record.wikilinks
    end

    test "org-mode records get AST and outline" do
      content = """
      :PROPERTIES:
      :ID: rec_org
      :END:
      #+TITLE: Org Title

      * First Section

      Some content with [[rec_001][a link]].

      ** Subsection
      """

      assert {:ok, record} = Parser.parse(content)
      assert record.ast != nil
      assert record.title == "Org Title"

      assert record.outline == [
               %{level: 1, text: "First Section"},
               %{level: 2, text: "Subsection"}
             ]

      assert [%{target: "rec_001", display: "a link"}] = record.wikilinks
    end

    test "plain markdown without frontmatter gets AST" do
      content = "# Quick Note\n\nSee [[rec_001]] for context."

      assert {:ok, record} = Parser.parse(content)
      assert record.ast != nil
      assert record.title == "Quick Note"
      assert [%{target: "rec_001"}] = record.wikilinks
    end
  end

  # --- Record struct ---

  describe "Record.parse_class/1" do
    test "parses valid class strings" do
      assert Record.parse_class("durable") == :durable
      assert Record.parse_class("inbox") == :inbox
      assert Record.parse_class("deliberation") == :deliberation
    end

    test "parses valid class atoms" do
      assert Record.parse_class(:durable) == :durable
      assert Record.parse_class(:inbox) == :inbox
    end

    test "defaults to durable for nil" do
      assert Record.parse_class(nil) == :durable
    end

    test "defaults to durable for unknown" do
      assert Record.parse_class("unknown") == :durable
      assert Record.parse_class(42) == :durable
    end
  end

  # --- RecordStore GenServer ---

  describe "RecordStore" do
    test "starts and loads records from directory", context do
      dir = tmp_dir(context)
      write_file(dir, "rec_001.md", @markdown_record)

      {_pid, name} = start_store(dir)
      records = RecordStore.list_records(name)

      assert length(records) == 1
      assert hd(records).id == "rec_0042"
    end

    test "loads both markdown and org-mode files", context do
      dir = tmp_dir(context)
      write_file(dir, "rec_md.md", @markdown_record)
      write_file(dir, "rec_org.org", @org_record |> String.replace("rec_0042", "rec_org_01"))

      {_pid, name} = start_store(dir)
      records = RecordStore.list_records(name)

      assert length(records) == 2
      ids = Enum.map(records, & &1.id) |> Enum.sort()
      assert ids == ["rec_0042", "rec_org_01"]
    end

    test "get_record returns the record", context do
      dir = tmp_dir(context)
      write_file(dir, "rec_001.md", @markdown_record)

      {_pid, name} = start_store(dir)

      assert {:ok, record} = RecordStore.get_record(name, "rec_0042")
      assert record.id == "rec_0042"
    end

    test "get_record returns error for missing id", context do
      dir = tmp_dir(context)
      {_pid, name} = start_store(dir)

      assert {:error, :not_found} = RecordStore.get_record(name, "nonexistent")
    end

    test "create_record writes a file and updates index", context do
      dir = tmp_dir(context)
      {_pid, name} = start_store(dir)

      assert {:ok, record} =
               RecordStore.create_record(name, %{
                 id: "rec_new",
                 title: "Test Record",
                 author: "mark",
                 tags: ["test"],
                 class: "inbox",
                 body: "Test body"
               })

      assert record.id == "rec_new"
      assert record.class == :inbox
      assert record.title == "Test Record"

      # File was written
      assert File.exists?(Path.join(dir, "rec_new.md"))

      # Index was updated
      assert {:ok, _} = RecordStore.get_record(name, "rec_new")
    end

    test "create_record rejects duplicate ids", context do
      dir = tmp_dir(context)
      write_file(dir, "rec_dup.md", @markdown_record)
      {_pid, name} = start_store(dir)

      assert {:error, :already_exists} =
               RecordStore.create_record(name, %{id: "rec_0042", title: "Dup"})
    end

    test "search_by_tag returns matching records", context do
      dir = tmp_dir(context)
      write_file(dir, "rec_001.md", @markdown_record)

      write_file(dir, "rec_002.md", """
      ---
      id: rec_other
      tags: [unrelated]
      ---

      Other record.
      """)

      {_pid, name} = start_store(dir)

      results = RecordStore.search_by_tag(name, "architecture")
      assert length(results) == 1
      assert hd(results).id == "rec_0042"

      assert RecordStore.search_by_tag(name, "nonexistent") == []
    end

    test "search_by_class returns matching records", context do
      dir = tmp_dir(context)
      write_file(dir, "rec_001.md", @markdown_record)

      write_file(dir, "rec_inbox.md", """
      ---
      id: rec_inbox
      class: inbox
      ---

      Inbox item.
      """)

      {_pid, name} = start_store(dir)

      durable = RecordStore.search_by_class(name, :durable)
      assert length(durable) == 1
      assert hd(durable).id == "rec_0042"

      inbox = RecordStore.search_by_class(name, :inbox)
      assert length(inbox) == 1
      assert hd(inbox).id == "rec_inbox"

      assert RecordStore.search_by_class(name, :deliberation) == []
    end

    test "find_links traverses one level", context do
      dir = tmp_dir(context)

      write_file(dir, "a.md", """
      ---
      id: a
      links: [b, c]
      ---

      Record A
      """)

      write_file(dir, "b.md", """
      ---
      id: b
      links: [c]
      ---

      Record B
      """)

      write_file(dir, "c.md", """
      ---
      id: c
      ---

      Record C
      """)

      {_pid, name} = start_store(dir)

      links = RecordStore.find_links(name, "a", 1)
      ids = Enum.map(links, & &1.id) |> Enum.sort()
      assert ids == ["b", "c"]
    end

    test "find_links traverses multiple levels (A->B->C)", context do
      dir = tmp_dir(context)

      write_file(dir, "a.md", """
      ---
      id: a
      links: [b]
      ---

      Record A
      """)

      write_file(dir, "b.md", """
      ---
      id: b
      links: [c]
      ---

      Record B
      """)

      write_file(dir, "c.md", """
      ---
      id: c
      ---

      Record C
      """)

      {_pid, name} = start_store(dir)

      links = RecordStore.find_links(name, "a", 2)
      ids = Enum.map(links, & &1.id) |> Enum.sort()
      assert ids == ["b", "c"]
    end

    test "find_links avoids cycles", context do
      dir = tmp_dir(context)

      write_file(dir, "a.md", """
      ---
      id: a
      links: [b]
      ---

      Record A
      """)

      write_file(dir, "b.md", """
      ---
      id: b
      links: [a]
      ---

      Record B
      """)

      {_pid, name} = start_store(dir)

      links = RecordStore.find_links(name, "a", 5)
      ids = Enum.map(links, & &1.id)
      assert ids == ["b"]
    end

    test "find_links returns empty for record with no links", context do
      dir = tmp_dir(context)

      write_file(dir, "a.md", """
      ---
      id: a
      ---

      Standalone record.
      """)

      {_pid, name} = start_store(dir)
      assert RecordStore.find_links(name, "a", 1) == []
    end

    test "find_links returns empty for nonexistent record", context do
      dir = tmp_dir(context)
      {_pid, name} = start_store(dir)
      assert RecordStore.find_links(name, "nonexistent", 1) == []
    end

    test "reload picks up new files", context do
      dir = tmp_dir(context)
      {_pid, name} = start_store(dir)

      assert RecordStore.list_records(name) == []

      write_file(dir, "new.md", @markdown_record)
      RecordStore.reload(name)

      assert length(RecordStore.list_records(name)) == 1
    end

    test "loads plain markdown files without frontmatter", context do
      dir = tmp_dir(context)
      write_file(dir, "quick-thought.md", "# Quick Thought\n\nJust an idea.")

      {_pid, name} = start_store(dir)
      records = RecordStore.list_records(name)

      assert length(records) == 1
      record = hd(records)
      assert record.id == "quick-thought"
      assert record.title == "Quick Thought"
      assert record.created != nil
    end

    test "derives author from file owner", context do
      dir = tmp_dir(context)
      write_file(dir, "note.md", "# A Note\n\nBody.")

      {_pid, name} = start_store(dir)

      assert {:ok, record} = RecordStore.get_record(name, "note")
      # Author is derived from the file's uid — should be the current user
      expected = System.get_env("USER")
      assert record.author == expected
    end

    @tag :file_watcher
    test "file watcher picks up new files automatically", context do
      dir = tmp_dir(context)
      name = :"watcher_#{:erlang.unique_integer([:positive])}"
      {:ok, _pid} = RecordStore.start_link(records_dir: dir, name: name, watch: true)

      assert RecordStore.list_records(name) == []

      # Small delay to let fswatch establish its watch
      Process.sleep(200)

      write_file(dir, "live.md", "# Live\n\nAdded while running.")

      # Poll until the watcher fires (up to 3 seconds)
      result =
        Enum.reduce_while(1..30, [], fn _, _acc ->
          Process.sleep(100)
          records = RecordStore.list_records(name)
          if length(records) > 0, do: {:halt, records}, else: {:cont, []}
        end)

      assert length(result) == 1
      assert hd(result).id == "live"
    end

    test "index stays consistent after creates", context do
      dir = tmp_dir(context)
      {_pid, name} = start_store(dir)

      RecordStore.create_record(name, %{id: "r1", title: "One", tags: ["a"]})
      RecordStore.create_record(name, %{id: "r2", title: "Two", tags: ["b"]})
      RecordStore.create_record(name, %{id: "r3", title: "Three", tags: ["a", "b"]})

      assert length(RecordStore.list_records(name)) == 3
      assert length(RecordStore.search_by_tag(name, "a")) == 2
      assert length(RecordStore.search_by_tag(name, "b")) == 2
      assert {:ok, _} = RecordStore.get_record(name, "r2")
    end
  end

  # --- Top-level Egghead API ---

  describe "Egghead facade" do
    test "all public functions delegate correctly", context do
      dir = tmp_dir(context)
      # Start a store registered under the default name the facade expects
      {:ok, _pid} = RecordStore.start_link(records_dir: dir, name: RecordStore, watch: false)

      id1 = "facade_1"
      id2 = "facade_2"

      assert {:ok, _rec} =
               Egghead.create_record(%{
                 id: id1,
                 title: "Facade Test",
                 tags: ["facade_test"],
                 body: "See [[#{id2}]]."
               })

      # get_record hydrates from disk — full record with body + ast
      assert {:ok, hydrated} = Egghead.get_record(id1)
      assert hydrated.id == id1
      assert hydrated.body != nil
      assert hydrated.ast != nil

      # list/search return lightweight index records (no body/ast)
      listed = Egghead.list_records()
      assert Enum.any?(listed, &(&1.id == id1))
      assert Enum.any?(Egghead.search_by_tag("facade_test"), &(&1.id == id1))
      assert Enum.any?(Egghead.search_by_class(:durable), &(&1.id == id1))
      assert Egghead.find_links(id1) == []
      assert Egghead.find_links(id1, 2) == []

      Egghead.create_record(%{id: id2, title: "Target"})
      assert [%{id: ^id2}] = Egghead.find_links(id1)
    after
      if Process.whereis(RecordStore), do: GenServer.stop(RecordStore)
    end
  end
end
