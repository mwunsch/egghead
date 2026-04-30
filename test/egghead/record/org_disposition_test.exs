defmodule Egghead.Record.OrgDispositionTest do
  use ExUnit.Case, async: true

  alias Egghead.Record.OrgParser

  describe "body_without_preamble/1" do
    test "strips leading #+ keywords" do
      content = """
      #+TITLE: Scout
      #+AUTHOR: mark

      You are a careful researcher.
      """

      assert OrgParser.body_without_preamble(content) == "You are a careful researcher."
    end

    test "strips a leading file-level :PROPERTIES: drawer" do
      content = """
      :PROPERTIES:
      :ID: agents/scout
      :CLASS: agent
      :END:

      You are a careful researcher.
      """

      assert OrgParser.body_without_preamble(content) == "You are a careful researcher."
    end

    test "strips both #+ keywords and a property drawer" do
      content = """
      #+TITLE: Scout
      #+FILETAGS: :agent:
      :PROPERTIES:
      :ID: agents/scout
      :CLASS: agent
      :CAPABILITIES: records.read
      :END:

      You are a careful researcher who looks before leaping.

      * Method

      Always cite sources.
      """

      out = OrgParser.body_without_preamble(content)
      assert String.starts_with?(out, "You are a careful researcher")
      assert out =~ "* Method"
      refute out =~ "#+TITLE:"
      refute out =~ ":PROPERTIES:"
    end

    test "leaves headline-attached drawers in place" do
      content = """
      #+TITLE: Scout

      * First section
      :PROPERTIES:
      :CUSTOM: keep-me
      :END:

      Body.
      """

      out = OrgParser.body_without_preamble(content)
      assert out =~ "* First section"
      assert out =~ ":CUSTOM: keep-me"
    end

    test "no preamble — returns trimmed body" do
      content = "* Heading\n\nBody.\n"
      assert OrgParser.body_without_preamble(content) == "* Heading\n\nBody."
    end

    test "preamble only — empty disposition" do
      content = """
      #+TITLE: T
      :PROPERTIES:
      :ID: x
      :END:
      """

      assert OrgParser.body_without_preamble(content) == ""
    end
  end

  describe "Record.Agent.from/1 disposition projection" do
    alias Egghead.Record
    alias Egghead.Record.Agent, as: AgentProj

    test "org agent's disposition skips the preamble" do
      record = %Record{
        id: "agents/scout",
        title: "Scout",
        format: :org,
        class: :agent,
        meta: %{"capabilities" => "records.read"},
        body: """
        #+TITLE: Scout
        :PROPERTIES:
        :ID: agents/scout
        :CLASS: agent
        :CAPABILITIES: records.read
        :END:

        You are a careful researcher.
        """
      }

      config = AgentProj.from(record)
      assert config.disposition == "You are a careful researcher."
    end

    test "markdown agent uses body verbatim (already post-frontmatter)" do
      record = %Record{
        id: "agents/scout",
        title: "Scout",
        format: :markdown,
        class: :agent,
        meta: %{"capabilities" => "records.read"},
        body: "You are a careful researcher."
      }

      assert AgentProj.from(record).disposition == "You are a careful researcher."
    end
  end
end
