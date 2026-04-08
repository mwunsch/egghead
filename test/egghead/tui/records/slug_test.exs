defmodule Egghead.TUI.Records.SlugTest do
  use ExUnit.Case, async: true

  alias Egghead.TUI.Records.Slug

  describe "slugify/1" do
    test "lowercases" do
      assert Slug.slugify("HelloWorld") == "helloworld"
      assert Slug.slugify("ALL CAPS") == "all-caps"
    end

    test "replaces non-alnum with dashes and collapses" do
      assert Slug.slugify("foo bar baz") == "foo-bar-baz"
      assert Slug.slugify("foo!!!bar???baz") == "foo-bar-baz"
      assert Slug.slugify("foo---bar") == "foo-bar"
    end

    test "preserves slashes for nested paths" do
      assert Slug.slugify("Agents/Scout") == "agents/scout"
      assert Slug.slugify("Agents / Scout") == "agents/scout"
      assert Slug.slugify("a / b / c") == "a/b/c"
    end

    test "trims leading and trailing dashes per segment" do
      assert Slug.slugify("-foo-") == "foo"
      assert Slug.slugify("--foo--/--bar--") == "foo/bar"
      assert Slug.slugify("/foo/bar/") == "foo/bar"
    end

    test "drops empty path segments" do
      assert Slug.slugify("foo//bar") == "foo/bar"
      assert Slug.slugify("///foo///") == "foo"
    end

    test "preserves underscores and dashes within tokens" do
      assert Slug.slugify("snake_case_id") == "snake_case_id"
      assert Slug.slugify("kebab-case-id") == "kebab-case-id"
    end

    test "strips unicode that's not in the allowed set" do
      assert Slug.slugify("Café — Notes") == "caf-notes"
    end

    test "empty input → empty slug" do
      assert Slug.slugify("") == ""
      assert Slug.slugify("   ") == ""
      assert Slug.slugify("!!!") == ""
      assert Slug.slugify("///") == ""
    end

    test "real-world example: free-form title to nested id" do
      assert Slug.slugify("My New Agent") == "my-new-agent"
      assert Slug.slugify("Design / OpenTUI Bridge") == "design/opentui-bridge"
    end
  end
end
