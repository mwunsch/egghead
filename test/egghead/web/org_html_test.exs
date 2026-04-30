defmodule Egghead.Web.OrgHTMLTest do
  use ExUnit.Case, async: true

  alias Egghead.Web.OrgHTML

  describe "headlines" do
    test "renders headline stars and text with org-headline class" do
      html = OrgHTML.render("* My Heading")
      assert html =~ ~s|<h1 class="org-headline" data-level="1">|
      assert html =~ ~s|<span class="org-stars">*</span>|
      assert html =~ ~s|<span class="org-headline-text">My Heading</span>|
    end

    test "level controls heading tag and stars" do
      html = OrgHTML.render("*** Third")
      assert html =~ ~s|<h3 class="org-headline" data-level="3">|
      assert html =~ ~s|<span class="org-stars">***</span>|
    end

    test "TODO keyword renders as a styled badge" do
      html = OrgHTML.render("* TODO Buy milk")
      assert html =~ ~s|<span class="org-todo org-todo-todo">TODO</span>|
      assert html =~ ~s|<span class="org-headline-text">Buy milk</span>|
    end

    test "DONE keyword has its own class" do
      html = OrgHTML.render("* DONE Wrote it")
      assert html =~ ~s|<span class="org-todo org-todo-done">DONE</span>|
    end

    test "priority cookie renders" do
      html = OrgHTML.render("* TODO [#A] Urgent")
      assert html =~ ~s|<span class="org-priority">[#A]</span>|
    end

    test "tags render as chips" do
      html = OrgHTML.render("* Heading :work:urgent:")
      assert html =~ ~s|<span class="org-tag">work</span>|
      assert html =~ ~s|<span class="org-tag">urgent</span>|
    end
  end

  describe "keywords" do
    test "#+TITLE renders visibly" do
      html = OrgHTML.render("#+TITLE: My Doc")

      assert html =~
               ~s|<div class="org-keyword" data-key="TITLE"><span class="org-keyword-key">#+TITLE:</span> <span class="org-keyword-value">My Doc</span></div>|
    end

    test "arbitrary #+KEY: keywords render with their key in data attr" do
      html = OrgHTML.render("#+OPTIONS: toc:nil num:nil")
      assert html =~ ~s|data-key="OPTIONS"|
      assert html =~ "toc:nil num:nil"
    end
  end

  describe "property drawer" do
    test "renders as a visible block with drawer markers" do
      html =
        OrgHTML.render("""
        :PROPERTIES:
        :ID: rec_1
        :CLASS: durable
        :END:
        """)

      assert html =~ ~s|<div class="org-property-drawer">|
      assert html =~ ~s|<div class="org-drawer-marker">:PROPERTIES:</div>|
      assert html =~ ~s|<div class="org-drawer-marker">:END:</div>|
      assert html =~ ~s|<span class="org-property-key">:ID:</span>|
      assert html =~ ~s|<span class="org-property-value">rec_1</span>|
    end
  end

  describe "source blocks" do
    test "frames code with #+BEGIN_SRC / #+END_SRC markers" do
      html =
        OrgHTML.render("""
        #+BEGIN_SRC elixir
        IO.puts("hi")
        #+END_SRC
        """)

      assert html =~ ~s|<div class="org-src-block" data-language="elixir">|
      assert html =~ ~s|<div class="org-block-marker org-block-begin">#+BEGIN_SRC elixir</div>|
      assert html =~ ~s|<div class="org-block-marker org-block-end">#+END_SRC</div>|
      assert html =~ ~s|<code class="language-elixir">IO.puts(&quot;hi&quot;)</code>|
    end

    test "no language still shows markers" do
      html =
        OrgHTML.render("""
        #+BEGIN_SRC
        bare
        #+END_SRC
        """)

      assert html =~ "#+BEGIN_SRC"
      assert html =~ "#+END_SRC"
      assert html =~ "bare"
    end
  end

  describe "links" do
    test "internal target becomes a wikilink with data-wikilink" do
      html = OrgHTML.render("See [[rec_other][the other]] please.")
      assert html =~ ~s|class="org-link wikilink"|
      assert html =~ ~s|data-wikilink="rec_other"|
      assert html =~ ~s|href="/records/rec_other"|
      assert html =~ ">the other</a>"
    end

    test "missing wikilink target gets the 'missing' class" do
      html = OrgHTML.render("[[ghost]]", exists_fn: fn _ -> false end)
      assert html =~ ~s|class="org-link wikilink missing"|
    end

    test "external https link is a plain anchor" do
      html = OrgHTML.render("[[https://example.com][example]]")
      assert html =~ ~s|class="org-link"|
      assert html =~ ~s|href="https://example.com"|
      refute html =~ "data-wikilink"
    end
  end

  describe "timestamps" do
    test "active timestamp keeps angle brackets" do
      html = OrgHTML.render("Meeting at <2026-04-30 Thu 10:00> sharp.")
      assert html =~ ~s|<time class="org-ts org-ts-active">|
      assert html =~ "&lt;2026-04-30 Thu 10:00&gt;"
    end

    test "inactive timestamp keeps square brackets" do
      html = OrgHTML.render("Logged [2026-04-30].")
      assert html =~ ~s|<time class="org-ts org-ts-inactive">|
      assert html =~ "[2026-04-30]"
    end
  end

  describe "lists with checkboxes" do
    test "renders task items with checkbox classes" do
      html =
        OrgHTML.render("""
        - [ ] todo item
        - [X] done item
        """)

      assert html =~ ~s|<li class="org-list-item org-task org-task-todo">|
      assert html =~ ~s|<li class="org-list-item org-task org-task-done">|
    end
  end

  describe "inline markup" do
    test "bold/italic/code/strikethrough" do
      html = OrgHTML.render("*bold* /italic/ ~code~ +nope+")
      assert html =~ "<strong>bold</strong>"
      assert html =~ "<em>italic</em>"
      assert html =~ ~s|<code class="org-code">code</code>|
      assert html =~ "<del>nope</del>"
    end
  end

  describe "safety" do
    test "escapes HTML in body" do
      html = OrgHTML.render("Plain text with <script>alert(1)</script>.")
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "escapes HTML in headline title" do
      html = OrgHTML.render("* <script>alert(1)</script>")
      refute html =~ "<script>alert"
      assert html =~ "&lt;script&gt;"
    end

    test "escapes HTML in keyword value" do
      html = OrgHTML.render("#+TITLE: <script>")
      refute html =~ "<script>alert"
      assert html =~ "&lt;script&gt;"
    end

    test "escapes HTML in source block content" do
      html =
        OrgHTML.render("""
        #+BEGIN_SRC html
        <script>x</script>
        #+END_SRC
        """)

      refute html =~ "<script>x</script>"
      assert html =~ "&lt;script&gt;x&lt;/script&gt;"
    end
  end

  describe "fidelity to the file" do
    test "all four pieces of a typical org file appear in the output" do
      org = """
      #+TITLE: My Notes
      #+AUTHOR: mark
      :PROPERTIES:
      :ID: rec_1
      :END:

      * TODO [#A] Important :work:

      Some content with [[other][a link]] and =verbatim=.

      #+BEGIN_SRC elixir
      :ok
      #+END_SRC
      """

      html = OrgHTML.render(org)

      # Frontmatter-like keywords are visible.
      assert html =~ "#+TITLE:"
      assert html =~ "#+AUTHOR:"
      # Drawer is visible.
      assert html =~ ":PROPERTIES:"
      assert html =~ ":END:"
      # Headline structure preserved.
      assert html =~ "TODO"
      assert html =~ "[#A]"
      assert html =~ ~s|<span class="org-tag">work</span>|
      # Body content rendered.
      assert html =~ "a link"
      assert html =~ ~s|<code class="org-verbatim">verbatim</code>|
      # Source block markers shown.
      assert html =~ "#+BEGIN_SRC elixir"
      assert html =~ "#+END_SRC"
    end
  end
end
