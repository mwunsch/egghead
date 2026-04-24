defmodule Egghead.Agent.WizardTest do
  use ExUnit.Case, async: true

  alias Egghead.Agent.Wizard

  describe "validate (access:)" do
    # No record store runs in this async test module, so we force
    # validation to fail on a different field (missing :model) in order
    # to inspect the error map without triggering the create_record path.

    test "accepts valid access modes — :access absent from errors" do
      for mode <- ["r", "w", "rw", "RW", " rw "] do
        {:error, errors} =
          Wizard.create(%{
            name: "scribe",
            # model omitted on purpose to short-circuit before create
            access: mode,
            instructions: "You are Scribe..."
          })

        refute Map.has_key?(errors, :access),
               "expected access=#{inspect(mode)} to validate, got errors #{inspect(errors)}"
      end
    end

    test "rejects invalid access value with a clear error" do
      assert {:error, errors} =
               Wizard.create(%{
                 name: "scribe",
                 access: "xyz",
                 instructions: "You are Scribe..."
               })

      assert Map.has_key?(errors, :access)
      [msg] = errors.access
      assert msg =~ "must be"
      assert msg =~ "xyz"
    end

    test "rejects non-string access" do
      assert {:error, errors} =
               Wizard.create(%{
                 name: "scribe",
                 access: 42,
                 instructions: "You are Scribe..."
               })

      assert Map.has_key?(errors, :access)
    end

    test "access is optional — omitting it leaves :access out of errors" do
      {:error, errors} =
        Wizard.create(%{
          name: "scribe",
          instructions: "You are Scribe..."
        })

      refute Map.has_key?(errors, :access)
    end
  end

  describe "validate (sandbox:)" do
    test "accepts a string sandbox path" do
      {:error, errors} =
        Wizard.create(%{
          name: "scout",
          # model omitted to short-circuit before create
          sandbox: "~/projects/foo",
          instructions: "You are Scout..."
        })

      refute Map.has_key?(errors, :sandbox)
    end

    test "allows nil/empty sandbox (optional)" do
      for value <- [nil, ""] do
        {:error, errors} =
          Wizard.create(%{
            name: "scout",
            sandbox: value,
            instructions: "You are Scout..."
          })

        refute Map.has_key?(errors, :sandbox),
               "expected sandbox=#{inspect(value)} to not produce a :sandbox error"
      end
    end

    test "rejects non-string sandbox" do
      {:error, errors} =
        Wizard.create(%{
          name: "scout",
          sandbox: 42,
          instructions: "You are Scout..."
        })

      assert Map.has_key?(errors, :sandbox)
      [msg] = errors.sandbox
      assert msg =~ "string path"
    end
  end

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
