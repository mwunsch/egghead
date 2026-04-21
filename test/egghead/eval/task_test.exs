defmodule Egghead.Eval.TaskTest do
  use ExUnit.Case, async: true

  alias Egghead.Eval.Task

  describe "bundled tasks" do
    test "lists the ported MARBLE research profiles" do
      tasks = Task.list()
      ids = Enum.map(tasks, & &1.id) |> Enum.sort()

      assert "research/profile-1" in ids
      assert "research/profile-2" in ids
      assert "research/profile-3" in ids
    end

    test "each bundled research task has the expected shape" do
      {:ok, task} = Task.fetch("research/profile-1")

      assert task.category == :research
      assert task.dialogue_mode == :open
      assert task.required_capabilities == ["records.read"]
      assert length(task.personas) == 5
      assert Enum.all?(task.personas, &String.starts_with?(&1, "researcher-p1-"))
      assert length(task.milestones) >= 3
      assert String.contains?(task.prompt, "Research Team")
    end

    test "fetch returns not_found for unknown task" do
      assert {:error, :not_found} = Task.fetch("nonexistent/task")
    end
  end

  describe "load_file" do
    @tag :tmp_dir
    test "parses an arbitrary task file", %{tmp_dir: dir} do
      path = Path.join(dir, "custom.md")

      File.write!(path, """
      ---
      id: custom/test
      category: research
      difficulty: easy
      required_capabilities: [records.read, fs.write]
      personas: [alice, bob]
      dialogue_mode: huddle
      milestones:
        - "First milestone"
        - "Second milestone"
      ---

      # Custom Task

      Please collaborate on an example task.
      """)

      {:ok, task} = Task.load_file(path)

      assert task.id == "custom/test"
      assert task.category == :research
      assert task.difficulty == :easy
      assert task.required_capabilities == ["records.read", "fs.write"]
      assert task.personas == ["alice", "bob"]
      assert task.dialogue_mode == :huddle
      assert task.milestones == ["First milestone", "Second milestone"]
    end

    @tag :tmp_dir
    test "errors on missing frontmatter", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.md")
      File.write!(path, "# Just a body, no frontmatter\n")

      assert {:error, :missing_frontmatter} = Task.load_file(path)
    end
  end
end
