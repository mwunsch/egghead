defmodule Egghead.Record.OrgParserTest do
  use ExUnit.Case

  alias Egghead.Record.OrgParser

  describe "headlines" do
    test "parses basic headlines at different levels" do
      {:ok, ast} = OrgParser.parse("* Level 1\n** Level 2\n*** Level 3")

      assert [
               {:headline, %{level: 1, title: "Level 1"}, _},
               {:headline, %{level: 2, title: "Level 2"}, _},
               {:headline, %{level: 3, title: "Level 3"}, _}
             ] = ast
    end

    test "parses TODO keyword" do
      {:ok, ast} = OrgParser.parse("* TODO Buy groceries")
      [{:headline, meta, _}] = ast
      assert meta.keyword == "TODO"
      assert meta.title == "Buy groceries"
    end

    test "parses DONE keyword" do
      {:ok, ast} = OrgParser.parse("* DONE Finished task")
      [{:headline, meta, _}] = ast
      assert meta.keyword == "DONE"
      assert meta.title == "Finished task"
    end

    test "parses priority" do
      {:ok, ast} = OrgParser.parse("* TODO [#A] Urgent task")
      [{:headline, meta, _}] = ast
      assert meta.keyword == "TODO"
      assert meta.priority == "A"
      assert meta.title == "Urgent task"
    end

    test "parses tags" do
      {:ok, ast} = OrgParser.parse("* My heading :tag1:tag2:tag3:")
      [{:headline, meta, _}] = ast
      assert meta.tags == ["tag1", "tag2", "tag3"]
      assert meta.title == "My heading"
    end

    test "parses full headline with keyword, priority, and tags" do
      {:ok, ast} = OrgParser.parse("* TODO [#B] Important task :work:urgent:")
      [{:headline, meta, _}] = ast
      assert meta.keyword == "TODO"
      assert meta.priority == "B"
      assert meta.tags == ["work", "urgent"]
      assert meta.title == "Important task"
    end

    test "headline without keyword or tags" do
      {:ok, ast} = OrgParser.parse("* Just a title")
      [{:headline, meta, _}] = ast
      assert meta.keyword == nil
      assert meta.priority == nil
      assert meta.tags == []
      assert meta.title == "Just a title"
    end
  end

  describe "keywords" do
    test "parses #+TITLE" do
      {:ok, ast} = OrgParser.parse("#+TITLE: My Document")
      [{:keyword, %{key: "TITLE", value: "My Document"}, _}] = ast
    end

    test "parses #+AUTHOR" do
      {:ok, ast} = OrgParser.parse("#+AUTHOR: Mark")
      [{:keyword, %{key: "AUTHOR", value: "Mark"}, _}] = ast
    end

    test "case insensitive" do
      {:ok, ast} = OrgParser.parse("#+title: lowercase title")
      [{:keyword, %{key: "TITLE", value: "lowercase title"}, _}] = ast
    end
  end

  describe "property drawer" do
    test "parses property drawer" do
      content = """
      :PROPERTIES:
      :ID: rec_001
      :AUTHOR: mark
      :CUSTOM: value
      :END:
      """

      {:ok, ast} = OrgParser.parse(content)

      assert [{:property_drawer, %{}, props}] = ast
      assert {"ID", "rec_001"} in props
      assert {"AUTHOR", "mark"} in props
      assert {"CUSTOM", "value"} in props
    end
  end

  describe "lists" do
    test "parses unordered list" do
      content = "- item one\n- item two\n- item three"
      {:ok, ast} = OrgParser.parse(content)

      assert [{:plain_list, %{}, items}] = ast
      assert length(items) == 3
      assert {:list_item, %{bullet: "-", checkbox: nil}, _} = hd(items)
    end

    test "parses checkboxes" do
      content = "- [ ] unchecked\n- [X] checked\n- [-] partial"
      {:ok, ast} = OrgParser.parse(content)

      [{:plain_list, %{}, items}] = ast

      assert [
               {:list_item, %{checkbox: :unchecked}, _},
               {:list_item, %{checkbox: :checked}, _},
               {:list_item, %{checkbox: :partial}, _}
             ] = items
    end

    test "parses ordered list" do
      content = "1. first\n2. second"
      {:ok, ast} = OrgParser.parse(content)

      [{:plain_list, %{}, items}] = ast
      assert length(items) == 2
      assert {:list_item, %{bullet: "1."}, _} = hd(items)
    end
  end

  describe "source blocks" do
    test "parses src block with language" do
      content = """
      #+BEGIN_SRC elixir
      def hello, do: :world
      #+END_SRC
      """

      {:ok, ast} = OrgParser.parse(content)
      assert [{:src_block, %{language: "elixir"}, "def hello, do: :world"}] = ast
    end

    test "parses src block without language" do
      content = """
      #+BEGIN_SRC
      some code
      #+END_SRC
      """

      {:ok, ast} = OrgParser.parse(content)
      assert [{:src_block, %{language: nil}, "some code"}] = ast
    end

    test "parses example block" do
      content = """
      #+BEGIN_EXAMPLE
      example text
      #+END_EXAMPLE
      """

      {:ok, ast} = OrgParser.parse(content)
      assert [{:example_block, %{}, "example text"}] = ast
    end

    test "preserves multiline content in blocks" do
      content = """
      #+BEGIN_SRC python
      def foo():
          return 42

      print(foo())
      #+END_SRC
      """

      {:ok, ast} = OrgParser.parse(content)
      [{:src_block, %{language: "python"}, code}] = ast
      assert code =~ "def foo():"
      assert code =~ "return 42"
      assert code =~ "print(foo())"
    end
  end

  describe "inline elements" do
    test "parses org links" do
      {:ok, ast} = OrgParser.parse("See [[target][display]] here.")
      [{:paragraph, _, inline}] = ast

      assert {:link, %{target: "target", display: "display"}} in inline
    end

    test "parses org link without display" do
      {:ok, ast} = OrgParser.parse("See [[target]] here.")
      [{:paragraph, _, inline}] = ast

      assert {:link, %{target: "target", display: nil}} in inline
    end

    test "parses bold text" do
      {:ok, ast} = OrgParser.parse("Some *bold* text.")
      [{:paragraph, _, inline}] = ast
      assert {:bold, "bold"} in inline
    end

    test "parses italic text" do
      {:ok, ast} = OrgParser.parse("Some /italic/ text.")
      [{:paragraph, _, inline}] = ast
      assert {:italic, "italic"} in inline
    end

    test "parses code text" do
      {:ok, ast} = OrgParser.parse("Some ~code~ text.")
      [{:paragraph, _, inline}] = ast
      assert {:code, "code"} in inline
    end

    test "parses verbatim text" do
      {:ok, ast} = OrgParser.parse("Some =verbatim= text.")
      [{:paragraph, _, inline}] = ast
      assert {:verbatim, "verbatim"} in inline
    end

    test "parses active timestamp" do
      {:ok, ast} = OrgParser.parse("Scheduled for <2026-03-25 Tue 10:00>.")
      [{:paragraph, _, inline}] = ast

      assert {:timestamp, %{type: :active, date: "2026-03-25", day: "Tue", time: "10:00"}} in inline
    end

    test "parses inactive timestamp" do
      {:ok, ast} = OrgParser.parse("Created [2026-03-25 Tue].")
      [{:paragraph, _, inline}] = ast

      assert {:timestamp, %{type: :inactive, date: "2026-03-25", day: "Tue", time: nil}} in inline
    end
  end

  describe "extract_title" do
    test "extracts from #+TITLE keyword" do
      {:ok, ast} = OrgParser.parse("#+TITLE: My Document\n\n* Heading")
      assert OrgParser.extract_title(ast) == "My Document"
    end

    test "falls back to first h1 when no #+TITLE" do
      {:ok, ast} = OrgParser.parse("* First Heading\n** Second")
      assert OrgParser.extract_title(ast) == "First Heading"
    end

    test "#+TITLE takes precedence over headline" do
      {:ok, ast} = OrgParser.parse("#+TITLE: The Real Title\n* Not This")
      assert OrgParser.extract_title(ast) == "The Real Title"
    end

    test "returns nil when no title found" do
      {:ok, ast} = OrgParser.parse("Just a paragraph.")
      assert OrgParser.extract_title(ast) == nil
    end
  end

  describe "extract_outline" do
    test "extracts all headlines with levels" do
      content = """
      * Chapter 1
      ** Section 1.1
      ** Section 1.2
      * Chapter 2
      *** Deep section
      """

      {:ok, ast} = OrgParser.parse(content)
      outline = OrgParser.extract_outline(ast)

      assert outline == [
               %{level: 1, text: "Chapter 1"},
               %{level: 2, text: "Section 1.1"},
               %{level: 2, text: "Section 1.2"},
               %{level: 1, text: "Chapter 2"},
               %{level: 3, text: "Deep section"}
             ]
    end
  end

  describe "extract_links" do
    test "extracts links from paragraphs" do
      {:ok, ast} = OrgParser.parse("See [[rec_001][first]] and [[rec_002]].")
      links = OrgParser.extract_links(ast)

      assert length(links) == 2
      assert %{target: "rec_001", display: "first", fragment: nil} in links
      assert %{target: "rec_002", display: nil, fragment: nil} in links
    end

    test "extracts links with fragments" do
      {:ok, ast} = OrgParser.parse("See [[rec_001#section][details]].")
      [link] = OrgParser.extract_links(ast)

      assert link.target == "rec_001"
      assert link.fragment == "section"
      assert link.display == "details"
    end
  end

  describe "extract_code_blocks" do
    test "extracts src blocks" do
      content = """
      #+BEGIN_SRC elixir
      IO.puts("hello")
      #+END_SRC

      #+BEGIN_SRC
      plain code
      #+END_SRC
      """

      {:ok, ast} = OrgParser.parse(content)
      blocks = OrgParser.extract_code_blocks(ast)

      assert length(blocks) == 2
      assert %{language: "elixir", content: "IO.puts(\"hello\")"} in blocks
      assert %{language: nil, content: "plain code"} in blocks
    end
  end

  describe "full document" do
    test "parses a complete org document" do
      content = """
      #+TITLE: Architecture Notes
      #+AUTHOR: mark

      * TODO [#A] Error Handling :architecture:

      Key insight: see [[rec_0038][service boundaries]].

      - [X] Define error types
      - [ ] Implement retry logic

      #+BEGIN_SRC elixir
      defmodule MyApp.Error do
        defstruct [:type, :message]
      end
      #+END_SRC

      * DONE Review Complete :review:

      Reviewed on [2026-03-25 Tue].
      """

      {:ok, ast} = OrgParser.parse(content)

      assert OrgParser.extract_title(ast) == "Architecture Notes"

      outline = OrgParser.extract_outline(ast)
      assert length(outline) == 2
      assert %{level: 1, text: "Error Handling"} in outline
      assert %{level: 1, text: "Review Complete"} in outline

      links = OrgParser.extract_links(ast)
      assert [%{target: "rec_0038", display: "service boundaries"}] = links

      blocks = OrgParser.extract_code_blocks(ast)
      assert [%{language: "elixir", content: content}] = blocks
      assert content =~ "defmodule MyApp.Error"
    end
  end
end
