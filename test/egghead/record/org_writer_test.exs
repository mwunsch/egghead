defmodule Egghead.Record.OrgWriterTest do
  use ExUnit.Case, async: true

  alias Egghead.Record.OrgWriter
  alias Egghead.Record.Parser

  describe "new/1 — render skeleton from attrs" do
    test "emits a #+TITLE keyword and properties drawer" do
      content =
        OrgWriter.new(%{
          "id" => "rec_001",
          "title" => "Hello",
          "author" => "mark",
          "tags" => ["alpha", "beta"],
          "links" => ["rec_002"],
          "class" => "durable",
          "body" => "First paragraph."
        })

      assert content =~ "#+TITLE: Hello"
      assert content =~ "#+AUTHOR: mark"
      assert content =~ "#+FILETAGS: :alpha:beta:"
      assert content =~ ":ID: rec_001"
      assert content =~ ":LINKS: rec_002"
      assert content =~ ":CLASS: durable"
      assert content =~ "First paragraph."
      assert String.ends_with?(content, "\n")
    end

    test "round-trips through the parser" do
      attrs = %{
        "id" => "rec_round",
        "title" => "Round Trip",
        "author" => "mark",
        "tags" => ["x", "y"],
        "links" => ["rec_a"],
        "class" => "durable",
        "body" => "* A heading\n\nSome body."
      }

      content = OrgWriter.new(attrs)

      assert {:ok, record} = Parser.parse(content)
      assert record.id == "rec_round"
      assert record.title == "Round Trip"
      assert record.author == "mark"
      assert record.tags == ["x", "y"]
      assert record.links == ["rec_a"]
      assert record.class == :durable
      assert record.format == :org
      assert record.body == String.trim_trailing(content)
    end

    test "extra meta fields go into the drawer" do
      content =
        OrgWriter.new(%{
          "id" => "rec_extra",
          "title" => "Extras",
          "description" => "A thing",
          "purpose" => "test"
        })

      assert content =~ ":DESCRIPTION: A thing"
      assert content =~ ":PURPOSE: test"
    end

    test "no body produces a preamble-only file" do
      content = OrgWriter.new(%{"id" => "rec_empty", "title" => "Empty"})
      assert String.ends_with?(content, ":END:\n")
      refute content =~ "\n\n\n"
    end
  end

  describe "splice_metadata/2 — preserves byte fidelity" do
    test "replaces an existing #+TITLE in place, preserving keyword casing" do
      original = """
      #+title: Original Title
      #+AUTHOR: mark

      Body text.
      """

      updated = OrgWriter.splice_metadata(original, %{"title" => "New Title"})

      # Keyword casing preserved.
      assert updated =~ ~r/^#\+title: New Title$/m
      # Author untouched.
      assert updated =~ "#+AUTHOR: mark"
      # Body untouched.
      assert updated =~ "Body text."
    end

    test "inserts a #+TITLE when absent" do
      original = """
      #+AUTHOR: mark

      Body text.
      """

      updated = OrgWriter.splice_metadata(original, %{"title" => "Inserted"})
      assert updated =~ "#+TITLE: Inserted"
      assert updated =~ "#+AUTHOR: mark"
      assert updated =~ "Body text."
    end

    test "replaces #+FILETAGS preserving form" do
      original = """
      #+TITLE: T
      #+FILETAGS: :old:tags:

      Body.
      """

      updated = OrgWriter.splice_metadata(original, %{"tags" => ["new", "tags"]})
      assert updated =~ "#+FILETAGS: :new:tags:"
      refute updated =~ ":old:"
    end

    test "falls back to existing #+TAGS line if user used that form" do
      original = """
      #+TITLE: T
      #+TAGS: foo bar

      Body.
      """

      updated = OrgWriter.splice_metadata(original, %{"tags" => ["baz"]})
      assert updated =~ "#+TAGS: :baz:"
      refute updated =~ "#+TAGS: foo"
    end

    test "edits properties drawer entries in place" do
      original = """
      #+TITLE: T
      :PROPERTIES:
      :ID: rec_old
      :CUSTOM: keep-me
      :CLASS: durable
      :END:

      Body.
      """

      updated =
        OrgWriter.splice_metadata(original, %{
          "id" => "rec_new",
          "class" => "inbox"
        })

      assert updated =~ ":ID: rec_new"
      assert updated =~ ":CLASS: inbox"
      # Custom drawer entry preserved.
      assert updated =~ ":CUSTOM: keep-me"
    end

    test "creates a properties drawer when missing" do
      original = """
      #+TITLE: T

      Body.
      """

      updated = OrgWriter.splice_metadata(original, %{"id" => "rec_x"})
      assert updated =~ ":PROPERTIES:\n:ID: rec_x\n:END:"
      assert updated =~ "Body."
    end

    test "ignores nil values (no-op)" do
      original = "#+TITLE: T\n\nBody.\n"
      updated = OrgWriter.splice_metadata(original, %{"title" => nil})
      assert updated == original
    end

    test ":remove deletes the keyword line" do
      original = """
      #+TITLE: Old
      #+AUTHOR: mark

      Body.
      """

      updated = OrgWriter.splice_metadata(original, %{"title" => :remove})
      refute updated =~ "#+TITLE:"
      assert updated =~ "#+AUTHOR: mark"
    end

    test "skips drawers attached to a headline (file-level only)" do
      original = """
      #+TITLE: T

      * First Heading
      :PROPERTIES:
      :ID: heading-id
      :END:

      Body under heading.
      """

      updated = OrgWriter.splice_metadata(original, %{"id" => "rec_file"})
      # The heading drawer's :ID stays the heading's.
      assert updated =~ ":ID: heading-id"
      # A file-level drawer was created at the top.
      assert updated =~ ~r/:PROPERTIES:\s*\n:ID: rec_file\s*\n:END:/
    end

    test "is byte-stable when no attrs change" do
      original = """
      #+TITLE: Stable
      #+AUTHOR: mark
      :PROPERTIES:
      :ID: rec_stable
      :CLASS: durable
      :END:

      * Content

      With paragraphs.
      """

      assert OrgWriter.splice_metadata(original, %{}) == original
    end

    test "byte-stability check across multiple metadata updates" do
      original = """
      #+TITLE: Original
      :PROPERTIES:
      :ID: rec_x
      :CLASS: durable
      :END:

      Body content here.
      """

      step1 = OrgWriter.splice_metadata(original, %{"title" => "Step 1"})
      step2 = OrgWriter.splice_metadata(step1, %{"title" => "Original"})

      # After round-tripping the title back, structural shape preserved.
      assert step2 =~ "#+TITLE: Original"
      assert step2 =~ ":ID: rec_x"
      assert step2 =~ "Body content here."
    end
  end

  describe "format_filetags/1" do
    test "wraps tags in colons" do
      assert OrgWriter.format_filetags(["a", "b", "c"]) == ":a:b:c:"
    end

    test "empty list returns empty string" do
      assert OrgWriter.format_filetags([]) == ""
    end
  end
end
