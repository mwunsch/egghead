defmodule Egghead.TUI.MarkdownTest do
  use ExUnit.Case, async: true

  alias Egghead.TUI.Markdown

  describe "basic rendering" do
    test "renders headings" do
      lines = Markdown.render("# H1\n## H2\n### H3", 60)
      texts = Enum.map(lines, fn {t, _} -> t end)
      assert "# H1" in texts
      assert "## H2" in texts
      assert "### H3" in texts
    end

    test "renders paragraphs with word wrapping" do
      long = "this is a long line that should be wrapped at the configured width"
      lines = Markdown.render(long, 30)
      assert length(lines) >= 2
    end

    test "renders bullet lists" do
      lines = Markdown.render("- one\n- two\n- three", 60)
      texts = Enum.map(lines, fn {t, _} -> t end)
      assert Enum.any?(texts, &(&1 =~ "· one"))
      assert Enum.any?(texts, &(&1 =~ "· two"))
    end
  end

  describe "wikilinks" do
    test "renders [[target]] inline" do
      lines = Markdown.render("Hello [[my-record]] world.", 60)
      texts = Enum.map(lines, fn {t, _} -> t end)
      assert Enum.any?(texts, &(&1 =~ "[[my-record]]"))
    end

    test "renders [[target|display]] preserving display text" do
      lines = Markdown.render("See [[my-record|the record]] for details.", 80)
      texts = Enum.map(lines, fn {t, _} -> t end)
      assert Enum.any?(texts, &(&1 =~ "[[my-record|the record]]"))
    end
  end

  describe "tables" do
    test "renders a simple GFM table with box characters" do
      md = """
      | Name | Age |
      |------|----:|
      | Alice | 30 |
      | Bob | 25 |
      """

      lines = Markdown.render(md, 60)
      texts = Enum.map(lines, fn {t, _} -> t end)

      assert Enum.any?(texts, &(&1 =~ "┌"))
      assert Enum.any?(texts, &(&1 =~ "└"))
      assert Enum.any?(texts, &(&1 =~ "Name"))
      assert Enum.any?(texts, &(&1 =~ "Alice"))
      assert Enum.any?(texts, &(&1 =~ "Bob"))
    end

    test "right-aligns numeric column" do
      md = """
      | Name | Age |
      |------|----:|
      | Alice | 30 |
      """

      lines = Markdown.render(md, 30)
      texts = Enum.map(lines, fn {t, _} -> t end)
      # Some line should have "30" with leading spaces (right alignment)
      assert Enum.any?(texts, &(&1 =~ ~r/\s+30 │/))
    end
  end

  describe "footnotes" do
    test "renders footnote reference as ^[id]" do
      md = """
      Hello[^1] world.

      [^1]: First footnote.
      """

      lines = Markdown.render(md, 60)
      texts = Enum.map(lines, fn {t, _} -> t end)
      assert Enum.any?(texts, &(&1 =~ "^[1]"))
    end

    test "renders footnote definitions section" do
      md = """
      See[^a].

      [^a]: My footnote.
      """

      lines = Markdown.render(md, 60)
      texts = Enum.map(lines, fn {t, _} -> t end)
      assert Enum.any?(texts, &(&1 =~ "Footnotes"))
      assert Enum.any?(texts, &(&1 =~ "[a] My footnote"))
    end
  end

  describe "task lists" do
    test "renders [ ] as unchecked checkbox" do
      lines = Markdown.render("- [ ] todo item", 60)
      texts = Enum.map(lines, fn {t, _} -> t end)
      assert Enum.any?(texts, &(&1 =~ "☐ todo item"))
    end

    test "renders [x] as checked checkbox" do
      lines = Markdown.render("- [x] done item", 60)
      texts = Enum.map(lines, fn {t, _} -> t end)
      assert Enum.any?(texts, &(&1 =~ "☑ done item"))
    end

    test "renders [X] (capital) as checked" do
      lines = Markdown.render("- [X] done", 60)
      texts = Enum.map(lines, fn {t, _} -> t end)
      assert Enum.any?(texts, &(&1 =~ "☑ done"))
    end

    test "non-task list items still get bullets" do
      lines = Markdown.render("- regular item", 60)
      texts = Enum.map(lines, fn {t, _} -> t end)
      assert Enum.any?(texts, &(&1 =~ "· regular item"))
    end
  end

  describe "find_wikilink_line" do
    test "finds the line index of a wikilink target" do
      lines = Markdown.render("first paragraph\n\nsecond [[my-target]] paragraph", 60)
      idx = Markdown.find_wikilink_line(lines, "my-target")
      assert is_integer(idx)
      assert idx > 0
    end

    test "returns nil when target not found" do
      lines = Markdown.render("just some text", 60)
      assert Markdown.find_wikilink_line(lines, "missing") == nil
    end

    test "finds piped wikilinks" do
      lines = Markdown.render("see [[some-id|nice display]]", 60)
      assert Markdown.find_wikilink_line(lines, "some-id") != nil
    end
  end
end
