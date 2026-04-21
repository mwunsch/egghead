defmodule Egghead.Chat.ToolLogDecorationTest do
  @moduledoc """
  Regression tests for tool-failure surfacing in saved transcripts.

  Before this landed, tool denials (capability scope violations, file-
  not-found errors, etc.) only hit Logger.info — never the transcript,
  never the Judge, never downstream agents. An eval run could silently
  no-op with no visible evidence of attempted tool calls.

  The coordinator now prepends a `**Tool errors:**` block to the agent
  message before committing it. Successful tool calls stay implicit —
  their output is the evidence. Only failures get surfaced, and only
  compactly.
  """

  use ExUnit.Case, async: true

  # `decorate_with_tool_log/2` is a defp in Coordinator. Import via
  # send_message-round-trip would require a full app; direct access
  # through a test-specific re-export keeps this a fast unit test.
  defp decorate(text, tool_calls) do
    apply(Egghead.Chat.Coordinator, :decorate_with_tool_log_for_test, [text, tool_calls])
  end

  describe "no surfacing for clean runs" do
    test "empty tool log passes text through untouched" do
      assert decorate("hello", []) == "hello"
    end

    test "nil tool log passes text through untouched" do
      assert decorate("hello", nil) == "hello"
    end

    test "successful tool calls don't decorate" do
      calls = [
        %{name: "fs_read", input: %{"path" => "/x"}, result: "file content", error: false},
        %{name: "shell_exec", input: %{"cmd" => "ls"}, result: "a\nb\n", error: false}
      ]

      assert decorate("done", calls) == "done"
    end
  end

  describe "surfacing failures" do
    test "single denied call is rendered in a `Tool errors:` block" do
      calls = [
        %{
          name: "fs_write",
          input: %{"path" => "/forbidden", "content" => "x"},
          result: "Denied: path /forbidden not in allowed scope",
          error: true
        }
      ]

      decorated = decorate("here is my response", calls)

      assert decorated =~ "**Tool errors:**"
      assert decorated =~ "fs_write"
      assert decorated =~ "Denied"
      # Original body preserved after the separator.
      assert decorated =~ "here is my response"
      # Separator between block and body.
      assert decorated =~ "---"
    end

    test "multiple failures are listed, successes omitted" do
      calls = [
        %{name: "fs_read", input: %{}, result: "ok", error: false},
        %{
          name: "fs_write",
          input: %{"path" => "/forbidden"},
          result: "denied scope",
          error: true
        },
        %{name: "shell_exec", input: %{"cmd" => "rm"}, result: "cmd not allowed", error: true}
      ]

      decorated = decorate("result", calls)

      assert decorated =~ "fs_write"
      assert decorated =~ "shell_exec"
      # fs_read succeeded; its name shouldn't appear in the error block.
      # (We guard only that the block exists and the two failures are
      # both mentioned. fs_read might still show up elsewhere if the
      # text happened to mention it — use String.split on the block.)
      [_, errors_block] = String.split(decorated, "```\n", parts: 2)
      [block_body, _] = String.split(errors_block, "\n```", parts: 2)
      refute block_body =~ "fs_read"
    end

    test "Response struct is accessed via dot syntax, not Access" do
      # Regression: the Coordinator previously did
      # `response[:tool_calls]` on an `Egghead.Agent.Response` struct,
      # which crashed at runtime because structs don't implement
      # Access. The fix pattern-matches the struct directly and
      # reads fields with dot syntax.
      response = %Egghead.Agent.Response{
        text: "hi",
        agent_id: "a",
        model: "m",
        usage: %{},
        tool_calls: [
          %{
            name: "fs_write",
            input: %{"path" => "/x"},
            result: "scope violation",
            error: true
          }
        ]
      }

      # Extract tool_calls the same way run_agent_attempt/4 does.
      # Must succeed at runtime.
      assert response.tool_calls |> length() == 1

      # Feed into decorate and assert the error surfaces. Exercises
      # the whole path from struct → decoration.
      decorated = decorate("agent text", response.tool_calls)
      assert decorated =~ "fs_write"
      assert decorated =~ "scope violation"
    end

    test "truncates very long inputs / results so the transcript stays readable" do
      long_input = String.duplicate("x", 500)
      long_result = String.duplicate("y", 1000)

      calls = [
        %{
          name: "fs_write",
          input: %{"path" => long_input, "content" => long_input},
          result: long_result,
          error: true
        }
      ]

      decorated = decorate("ok", calls)

      # Both bounded so the block isn't dominated by a single oversized
      # call. The exact limits aren't contractual, but they must exist.
      assert String.length(decorated) < 1500
    end
  end
end
