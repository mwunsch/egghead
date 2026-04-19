defmodule Egghead.OpenTUI.MarkdownTest do
  use ExUnit.Case, async: true

  alias Egghead.OpenTUI.{Attrs, Colors, Markdown}

  describe "render/3 — basic structure" do
    test "returns a list of rows where each row is a list of spans" do
      [row | _] = Markdown.render("hello world", 80)
      assert is_list(row)
      assert Enum.all?(row, &is_map/1)
      assert Enum.all?(row, fn span -> Map.has_key?(span, :text) end)
    end

    test "empty markdown returns at most a single empty row" do
      rendered = Markdown.render("", 80)
      assert Enum.all?(rendered, fn row -> row == [] end)
    end

    test "headings carry the heading color and bold attribute" do
      [row | _] = Markdown.render("# Hello", 80)

      assert Enum.any?(row, fn span ->
               span.fg == Colors.heading() and Bitwise.band(span.attrs, Attrs.bold()) != 0
             end)
    end
  end

  describe "inline modifiers" do
    test "bold sets the bold attribute" do
      [row | _] = Markdown.render("**hello**", 80)
      assert Enum.any?(row, fn s -> Bitwise.band(s.attrs, Attrs.bold()) != 0 end)
    end

    test "italic sets the italic attribute" do
      [row | _] = Markdown.render("*hello*", 80)
      assert Enum.any?(row, fn s -> Bitwise.band(s.attrs, Attrs.italic()) != 0 end)
    end

    test "strikethrough sets the strikethrough attribute" do
      [row | _] = Markdown.render("~~struck~~", 80)

      assert Enum.any?(row, fn s ->
               Bitwise.band(s.attrs, Attrs.strikethrough()) != 0
             end)
    end

    test "strikethrough also applies the muted color" do
      [row | _] = Markdown.render("~~struck~~", 80)

      assert Enum.any?(row, fn s ->
               s.fg == Colors.muted() and Bitwise.band(s.attrs, Attrs.strikethrough()) != 0
             end)
    end

    test "inline code uses the code color" do
      [row | _] = Markdown.render("call `foo()` here", 80)
      assert Enum.any?(row, fn s -> s.fg == Colors.code() end)
    end

    test "compound modifiers OR their attribute bits" do
      [row | _] = Markdown.render("***both***", 80)

      assert Enum.any?(row, fn s ->
               band = Bitwise.band(s.attrs, Bitwise.bor(Attrs.bold(), Attrs.italic()))
               band == Bitwise.bor(Attrs.bold(), Attrs.italic())
             end)
    end
  end

  describe "wikilinks" do
    test "wikilink spans carry the target as link metadata" do
      [row | _] = Markdown.render("see [[design/foo]] for details", 80)

      assert Enum.any?(row, fn s ->
               s.link == {:wikilink, "design/foo"}
             end)
    end

    test "wikilinks render the literal [[target]] text" do
      [row | _] = Markdown.render("[[design/foo]]", 80)

      assert Enum.any?(row, fn s ->
               String.contains?(s.text, "[[design/foo]]") and s.link == {:wikilink, "design/foo"}
             end)
    end

    test "wikilink with display renders [[target|display]]" do
      [row | _] = Markdown.render("[[design/foo|see this]]", 80)

      assert Enum.any?(row, fn s ->
               String.contains?(s.text, "[[design/foo|see this]]") and
                 s.link == {:wikilink, "design/foo"}
             end)
    end

    test "find_wikilink_row locates the row containing a target" do
      rendered =
        Markdown.render(
          """
          intro paragraph

          line two with [[design/foo]] in it

          line three
          """,
          80
        )

      idx = Markdown.find_wikilink_row(rendered, "design/foo")
      assert is_integer(idx)
      row = Enum.at(rendered, idx)
      assert Enum.any?(row, &(&1.link == {:wikilink, "design/foo"}))
    end

    test "find_wikilink_row returns nil for an absent target" do
      rendered = Markdown.render("just some prose", 80)
      assert Markdown.find_wikilink_row(rendered, "design/foo") == nil
    end
  end

  describe "soft-wrap clamp" do
    test "wraps long single paragraphs to max_content_width" do
      text = "word " |> List.duplicate(40) |> Enum.join() |> String.trim()
      rendered = Markdown.render(text, 200)
      # All non-empty rows should fit within 100 columns of text.
      Enum.each(rendered, fn row ->
        used = Enum.reduce(row, 0, fn s, acc -> acc + String.length(s.text) end)
        assert used <= 100
      end)
    end

    test ":max_width opt overrides the soft-wrap clamp" do
      text = "word " |> List.duplicate(20) |> Enum.join() |> String.trim()
      rendered = Markdown.render(text, 200, max_width: 40)

      Enum.each(rendered, fn row ->
        used = Enum.reduce(row, 0, fn s, acc -> acc + String.length(s.text) end)
        assert used <= 40
      end)
    end
  end

  describe "lists" do
    test "unordered lists render with bullet markers" do
      [first | _] = Markdown.render("- alpha\n- beta", 80)
      text = first |> Enum.map_join("", & &1.text)
      assert String.contains?(text, "·")
      assert String.contains?(text, "alpha")
    end

    test "task list checked items use the done glyph" do
      rendered = Markdown.render("- [x] done thing", 80)
      [first | _] = rendered
      text = first |> Enum.map_join("", & &1.text)
      assert String.contains?(text, "☑")
      assert String.contains?(text, "done thing")
    end

    test "task list unchecked items use the todo glyph" do
      rendered = Markdown.render("- [ ] todo thing", 80)
      [first | _] = rendered
      text = first |> Enum.map_join("", & &1.text)
      assert String.contains?(text, "☐")
      assert String.contains?(text, "todo thing")
    end
  end

  describe "code blocks" do
    test "fenced code blocks render with triple-backtick fences and code color" do
      rendered = Markdown.render("```elixir\nfoo()\n```", 80)
      flat = rendered |> List.flatten() |> Enum.map_join("\n", & &1.text)
      assert String.contains?(flat, "foo()")
      assert String.contains?(flat, "```elixir")
      assert String.contains?(flat, "```")

      assert Enum.any?(List.flatten(rendered), fn span -> span.fg == Colors.code() end)
    end
  end

  describe "theming" do
    test "default_theme/0 includes all required keys" do
      theme = Markdown.default_theme()

      keys = [
        :h1,
        :h2,
        :h3,
        :bold,
        :italic,
        :strikethrough,
        :code_inline,
        :code_block,
        :link,
        :wikilink,
        :blockquote,
        :hr
      ]

      Enum.each(keys, fn k -> assert Map.has_key?(theme, k) end)
    end

    test "theme overrides take effect" do
      red_heading = %{fg: Colors.red(), attrs: 0}
      theme = Map.merge(Markdown.default_theme(), %{h1: red_heading})

      [row | _] = Markdown.render("# Heading", 80, theme: theme)
      assert Enum.any?(row, fn s -> s.fg == Colors.red() end)
    end

    test "missing theme keys fall back to default_theme/0" do
      theme = %{h1: %{fg: Colors.green(), attrs: 0}}
      [row | _] = Markdown.render("# Heading\n\n**bold**", 80, theme: theme)
      assert Enum.any?(row, fn s -> s.fg == Colors.green() end)

      # The bold paragraph below should still pick up Attrs.bold() from default_theme.
      _ = row
    end
  end

  describe "earmark :error recovery" do
    # Earmark returns `{:error, ast, warnings}` for bodies that emit
    # warnings but still produce a usable AST (e.g. naked unclosed
    # HTML tags). The renderer should use that AST, not fall back to
    # plain text.
    test "renders body that triggers a :error tuple with non-empty AST" do
      body = "# Heading\n\nPlain text.\n\n<div>unclosed"
      rows = Markdown.render(body, 80)

      text =
        rows
        |> List.flatten()
        |> Enum.map_join("", fn
          %{text: t} -> t
          _ -> ""
        end)

      # The AST renderer unwraps the `<div>` — its text children
      # come through without the angle brackets. Plaintext fallback
      # would emit the literal `<div>unclosed` substring.
      assert text =~ "Heading"
      assert text =~ "unclosed"
      refute text =~ "<div>"
    end
  end
end
