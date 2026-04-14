defmodule Egghead.Agent.WizardTest do
  use ExUnit.Case, async: true

  alias Egghead.Agent.Wizard

  describe "slugify/1" do
    test "lowercases and hyphen-joins words" do
      assert Wizard.slugify("Capability Test") == "capability-test"
      assert Wizard.slugify("Cross Domain Scout") == "cross-domain-scout"
    end

    test "preserves existing slugs" do
      assert Wizard.slugify("scout") == "scout"
      assert Wizard.slugify("my-agent") == "my-agent"
      assert Wizard.slugify("foo_bar") == "foo_bar"
    end

    test "collapses runs of separators" do
      assert Wizard.slugify("foo  bar") == "foo-bar"
      assert Wizard.slugify("foo---bar") == "foo-bar"
      assert Wizard.slugify("foo  -- bar") == "foo-bar"
    end

    test "strips leading/trailing junk" do
      assert Wizard.slugify("  hello  ") == "hello"
      assert Wizard.slugify("!!scout!!") == "scout"
    end

    test "drops unicode and punctuation" do
      assert Wizard.slugify("Cafe's Agent") == "cafe-s-agent"
      assert Wizard.slugify("Hello, World!") == "hello-world"
    end

    test "empty-ish input returns empty string (caller validates)" do
      assert Wizard.slugify("") == ""
      assert Wizard.slugify("!!!") == ""
      assert Wizard.slugify("   ") == ""
    end

    test "nil passes through" do
      assert Wizard.slugify(nil) == nil
    end
  end
end
