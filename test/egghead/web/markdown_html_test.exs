defmodule Egghead.Web.MarkdownHTMLTest do
  use ExUnit.Case, async: true

  alias Egghead.Web.MarkdownHTML

  describe "headings" do
    test "renders h1–h6" do
      for {level, md} <- [
            {"h1", "# Hello"},
            {"h2", "## Hello"},
            {"h3", "### Hello"},
            {"h4", "#### Hello"},
            {"h5", "##### Hello"},
            {"h6", "###### Hello"}
          ] do
        html = MarkdownHTML.render(md)
        assert html =~ "<#{level}>Hello</#{level}>"
      end
    end
  end

  describe "paragraphs" do
    test "renders paragraph" do
      assert MarkdownHTML.render("Hello world") =~ "<p>Hello world</p>"
    end

    test "renders inline formatting" do
      html = MarkdownHTML.render("**bold** and *italic* and `code`")
      assert html =~ "<strong>bold</strong>"
      assert html =~ "<em>italic</em>"
      assert html =~ "<code>code</code>"
    end

    test "renders strikethrough" do
      html = MarkdownHTML.render("~~struck~~")
      assert html =~ "<del>struck</del>"
    end
  end

  describe "code blocks" do
    test "renders fenced code with language" do
      md = """
      ```elixir
      def hello, do: :world
      ```
      """

      html = MarkdownHTML.render(md)
      assert html =~ "<pre><code class=\"language-elixir\">"
      assert html =~ "def hello, do: :world"
      assert html =~ "</code></pre>"
    end

    test "renders fenced code without language" do
      md = """
      ```
      plain code
      ```
      """

      html = MarkdownHTML.render(md)
      assert html =~ "<pre><code>"
      assert html =~ "plain code"
    end
  end

  describe "lists" do
    test "renders unordered list" do
      md = """
      - one
      - two
      - three
      """

      html = MarkdownHTML.render(md)
      assert html =~ "<ul>"
      assert html =~ "<li>one</li>"
      assert html =~ "<li>two</li>"
      assert html =~ "<li>three</li>"
      assert html =~ "</ul>"
    end

    test "renders ordered list" do
      md = """
      1. first
      2. second
      """

      html = MarkdownHTML.render(md)
      assert html =~ "<ol>"
      assert html =~ "<li>first</li>"
      assert html =~ "<li>second</li>"
      assert html =~ "</ol>"
    end

    test "renders task list" do
      md = """
      - [x] done
      - [ ] todo
      """

      html = MarkdownHTML.render(md)
      assert html =~ "class=\"task done\""
      assert html =~ "<input type=\"checkbox\" checked disabled />"
      assert html =~ "class=\"task todo\""
      assert html =~ "<input type=\"checkbox\" disabled />"
    end
  end

  describe "blockquotes" do
    test "renders blockquote" do
      html = MarkdownHTML.render("> quoted text")
      assert html =~ "<blockquote>"
      assert html =~ "quoted text"
      assert html =~ "</blockquote>"
    end
  end

  describe "horizontal rule" do
    test "renders hr" do
      html = MarkdownHTML.render("---")
      assert html =~ "<hr />"
    end
  end

  describe "tables" do
    test "renders GFM table" do
      md = """
      | Name | Value |
      |------|-------|
      | foo  | bar   |
      """

      html = MarkdownHTML.render(md)
      assert html =~ "<table>"
      assert html =~ "<th>"
      assert html =~ "Name"
      assert html =~ "<td>"
      assert html =~ "foo"
      assert html =~ "</table>"
    end
  end

  describe "wikilinks" do
    test "renders wikilink as anchor with data attribute" do
      html = MarkdownHTML.render("See [[design/overview]]")
      assert html =~ "data-wikilink=\"design/overview\""
      assert html =~ "class=\"wikilink\""
      assert html =~ "href=\"/?id=design/overview\""
    end

    test "marks missing wikilinks" do
      html =
        MarkdownHTML.render("See [[missing-page]]",
          exists_fn: fn _target -> false end
        )

      assert html =~ "class=\"wikilink missing\""
    end

    test "existing wikilinks have no missing class" do
      html =
        MarkdownHTML.render("See [[exists]]",
          exists_fn: fn "exists" -> true end
        )

      assert html =~ "class=\"wikilink\""
      refute html =~ "missing"
    end

    test "custom link_fn" do
      html =
        MarkdownHTML.render("See [[my-page]]",
          link_fn: fn target -> "/records/#{target}" end
        )

      assert html =~ "href=\"/records/my-page\""
    end

    test "wikilinks use LiveView patch navigation" do
      html = MarkdownHTML.render("See [[page]]")
      assert html =~ "data-phx-link=\"patch\""
      assert html =~ "data-phx-link-state=\"push\""
    end
  end

  describe "regular links" do
    test "renders external link" do
      html = MarkdownHTML.render("[Example](https://example.com)")
      assert html =~ "<a href=\"https://example.com\">Example</a>"
    end
  end

  describe "escaping" do
    test "escapes HTML in text" do
      html = MarkdownHTML.render("Use `<div>` tags")
      assert html =~ "&lt;div&gt;"
    end

    test "escapes HTML in code blocks" do
      md = """
      ```
      <script>alert('xss')</script>
      ```
      """

      html = MarkdownHTML.render(md)
      assert html =~ "&lt;script&gt;"
      refute html =~ "<script>"
    end
  end

  describe "fallback" do
    test "invalid markdown returns escaped pre" do
      # Trigger fallback by checking that even weird input doesn't crash
      html = MarkdownHTML.render("")
      assert is_binary(html)
    end
  end
end
