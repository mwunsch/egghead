defmodule Egghead.TUI.OrgRenderTest do
  use ExUnit.Case, async: true

  alias Egghead.TUI.OrgRender

  defp flatten_text(rows) do
    rows
    |> Enum.map(fn row -> Enum.map_join(row, "", & &1.text) end)
    |> Enum.join("\n")
  end

  describe "headlines" do
    test "preserves stars" do
      rows = OrgRender.render("** Heading", 80)
      text = flatten_text(rows)
      assert text =~ "** Heading"
    end

    test "renders TODO keyword and tags" do
      rows = OrgRender.render("* TODO Buy milk :work:home:", 80)
      text = flatten_text(rows)
      assert text =~ "* TODO Buy milk"
      assert text =~ ":work:home:"
    end

    test "renders priority cookie" do
      rows = OrgRender.render("* TODO [#A] Urgent", 80)
      text = flatten_text(rows)
      assert text =~ "[#A]"
    end
  end

  describe "keywords" do
    test "#+TITLE keyword stays visible" do
      rows = OrgRender.render("#+TITLE: My Doc", 80)
      text = flatten_text(rows)
      assert text =~ "#+TITLE: My Doc"
    end
  end

  describe "property drawer" do
    test "drawer markers and entries appear" do
      rows =
        OrgRender.render(
          """
          :PROPERTIES:
          :ID: rec_1
          :CLASS: durable
          :END:
          """,
          80
        )

      text = flatten_text(rows)
      assert text =~ ":PROPERTIES:"
      assert text =~ ":ID: rec_1"
      assert text =~ ":CLASS: durable"
      assert text =~ ":END:"
    end
  end

  describe "source blocks" do
    test "shows BEGIN_SRC / END_SRC markers around code" do
      rows =
        OrgRender.render(
          """
          #+BEGIN_SRC elixir
          IO.puts("hi")
          #+END_SRC
          """,
          80
        )

      text = flatten_text(rows)
      assert text =~ "#+BEGIN_SRC elixir"
      assert text =~ "IO.puts"
      assert text =~ "#+END_SRC"
    end
  end

  describe "links" do
    test "wikilink span carries the target for navigation" do
      rows = OrgRender.render("See [[other-record][the link]].", 80)

      span =
        rows
        |> List.flatten()
        |> Enum.find(fn s -> s.link == {:wikilink, "other-record"} end)

      assert span != nil
      assert span.text =~ "[[other-record]"
    end

    test "external link is not tagged as wikilink" do
      rows = OrgRender.render("Visit [[https://example.com][example]].", 80)

      assert Enum.any?(List.flatten(rows), fn s ->
               s.text =~ "https://example.com" and s.link == nil
             end)
    end
  end

  describe "timestamps" do
    test "active timestamp keeps angle brackets" do
      rows = OrgRender.render("Met at <2026-04-30 Thu 10:00>.", 80)
      text = flatten_text(rows)
      assert text =~ "<2026-04-30 Thu 10:00>"
    end

    test "inactive timestamp keeps square brackets" do
      rows = OrgRender.render("Logged [2026-04-30].", 80)
      text = flatten_text(rows)
      assert text =~ "[2026-04-30]"
    end
  end

  describe "lists" do
    test "renders bullets and checkboxes" do
      rows =
        OrgRender.render(
          """
          - [ ] todo
          - [X] done
          - regular bullet
          """,
          80
        )

      text = flatten_text(rows)
      assert text =~ "☐"
      assert text =~ "☑"
    end
  end

  describe "inline markup" do
    test "preserves the org markers" do
      rows = OrgRender.render("Some *bold* and /italic/ and ~code~ words.", 80)
      text = flatten_text(rows)
      assert text =~ "*bold*"
      assert text =~ "/italic/"
      assert text =~ "~code~"
    end
  end

  describe "fallback safety" do
    test "non-binary input returns empty rows but doesn't crash" do
      assert OrgRender.render("", 80) == []
    end
  end

  describe "paragraphs across multiple source lines" do
    test "joins lines with a single space (no concatenation)" do
      org = """
      You are Borges. Your home is the archive — not as warehouse but as
      instrument. Records are not where knowledge is *stored*.
      """

      rows = OrgRender.render(org, 200)
      text = flatten_text(rows)
      assert text =~ "but as instrument"
      refute text =~ "asinstrument"
    end

    test "wraps a long paragraph at the requested width" do
      org =
        String.duplicate("hello ", 30)
        |> String.trim_trailing()
        |> Kernel.<>(".")

      rows = OrgRender.render(org, 40)

      # No row exceeds the width.
      max_row_width =
        rows
        |> Enum.map(fn row -> row |> Enum.map(&String.length(&1.text)) |> Enum.sum() end)
        |> Enum.max(fn -> 0 end)

      assert max_row_width <= 40
      # And we have *more than one* row — wrap actually happened.
      content_rows = Enum.reject(rows, &(&1 == []))
      assert length(content_rows) > 1
    end

    test "inline markup survives across source-wrapped lines" do
      org = """
      Some text *that is bold* spans
      two source lines but parses fine.
      """

      rows = OrgRender.render(org, 200)

      bold_span =
        rows
        |> List.flatten()
        |> Enum.find(fn s -> s.text == "*that is bold*" end)

      assert bold_span != nil
    end
  end
end
