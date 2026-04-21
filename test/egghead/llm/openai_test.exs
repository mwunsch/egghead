defmodule Egghead.LLM.OpenAITest do
  use ExUnit.Case, async: true

  alias Egghead.LLM.OpenAI

  describe "build_body/2 — token-key selection" do
    test "uses max_completion_tokens for GPT-5 family against api.openai.com" do
      body = OpenAI.build_body([%{role: "user", content: "hi"}], model: "gpt-5.4")

      assert Map.has_key?(body, :max_completion_tokens)
      refute Map.has_key?(body, :max_tokens)
    end

    test "uses max_completion_tokens for o3/o4 reasoning models" do
      for model <- ~w(o1 o1-mini o3 o3-mini o4-mini o5) do
        body = OpenAI.build_body([%{role: "user", content: "hi"}], model: model)

        assert Map.has_key?(body, :max_completion_tokens),
               "expected max_completion_tokens for #{model}"

        refute Map.has_key?(body, :max_tokens), "#{model} must not send legacy max_tokens"
      end
    end

    test "uses legacy max_tokens for gpt-4o / gpt-4 / gpt-3.5" do
      for model <- ~w(gpt-4o gpt-4o-mini gpt-4-turbo gpt-4 gpt-3.5-turbo) do
        body = OpenAI.build_body([%{role: "user", content: "hi"}], model: model)
        assert Map.has_key?(body, :max_tokens), "expected max_tokens for #{model}"

        refute Map.has_key?(body, :max_completion_tokens),
               "#{model} must not send max_completion_tokens"
      end
    end

    test "uses legacy max_tokens on OpenAI-compatible endpoints even for gpt-5" do
      # Ollama, LMStudio, vLLM etc. don't understand max_completion_tokens
      body =
        OpenAI.build_body([%{role: "user", content: "hi"}],
          model: "gpt-5.4",
          base_url: "http://localhost:11434/v1"
        )

      assert Map.has_key?(body, :max_tokens)
      refute Map.has_key?(body, :max_completion_tokens)
    end
  end

  describe "build_body/2 — temperature handling" do
    test "drops temperature for reasoning/GPT-5 models on api.openai.com" do
      # These models only accept the default (1). Sending 0.7 returns 400.
      body =
        OpenAI.build_body([%{role: "user", content: "hi"}], model: "gpt-5.4", temperature: 0.7)

      refute Map.has_key?(body, :temperature)

      body =
        OpenAI.build_body([%{role: "user", content: "hi"}], model: "o3-mini", temperature: 0.2)

      refute Map.has_key?(body, :temperature)
    end

    test "keeps temperature for non-reasoning models" do
      body =
        OpenAI.build_body([%{role: "user", content: "hi"}], model: "gpt-4o", temperature: 0.7)

      assert body[:temperature] == 0.7
    end

    test "keeps temperature on OpenAI-compatible endpoints regardless of model" do
      body =
        OpenAI.build_body([%{role: "user", content: "hi"}],
          model: "gpt-5",
          temperature: 0.5,
          base_url: "http://localhost:11434/v1"
        )

      assert body[:temperature] == 0.5
    end
  end

  describe "build_body/2 — message shape" do
    test "prepends system message into messages array" do
      body =
        OpenAI.build_body([%{role: "user", content: "hello"}],
          model: "gpt-4o",
          system: "You are a test."
        )

      assert [%{role: "system", content: "You are a test."}, %{role: "user", content: "hello"}] =
               body[:messages]
    end

    test "assistant message with empty list content coerces to empty string (not null)" do
      # Regression: OpenAI rejects `{content: null}` unless `tool_calls`
      # is present. An assistant turn that filters down to neither
      # text nor tool_use blocks used to emit `content: nil` and
      # trip a 400 "expected a string, got null" deep in a session.
      body = OpenAI.build_body([%{role: "assistant", content: []}], model: "gpt-4o")

      assert [%{role: "assistant", content: ""} = msg] = body[:messages]
      refute Map.has_key?(msg, :tool_calls)
    end

    test "assistant message with only tool_use blocks keeps null content + tool_calls" do
      body =
        OpenAI.build_body(
          [
            %{
              role: "assistant",
              content: [%{"type" => "tool_use", "id" => "c1", "name" => "search", "input" => %{}}]
            }
          ],
          model: "gpt-4o"
        )

      assert [%{role: "assistant", content: nil, tool_calls: [_]}] = body[:messages]
    end

    test "nil-content user message defaults to empty string" do
      body = OpenAI.build_body([%{role: "user", content: nil}], model: "gpt-4o")
      assert [%{role: "user", content: ""}] = body[:messages]
    end
  end

  describe "chat_model?/1" do
    test "keeps gpt, chatgpt, and o-series chat models" do
      assert OpenAI.chat_model?("gpt-4o")
      assert OpenAI.chat_model?("gpt-4o-mini")
      assert OpenAI.chat_model?("gpt-5")
      assert OpenAI.chat_model?("gpt-5.4")
      assert OpenAI.chat_model?("chatgpt-4o-latest")
      assert OpenAI.chat_model?("o1")
      assert OpenAI.chat_model?("o3-mini")
      assert OpenAI.chat_model?("o4-mini")
    end

    test "filters out non-chat modalities" do
      refute OpenAI.chat_model?("text-embedding-3-small")
      refute OpenAI.chat_model?("text-embedding-ada-002")
      refute OpenAI.chat_model?("whisper-1")
      refute OpenAI.chat_model?("tts-1")
      refute OpenAI.chat_model?("tts-1-hd")
      refute OpenAI.chat_model?("dall-e-3")
      refute OpenAI.chat_model?("text-moderation-latest")
      refute OpenAI.chat_model?("gpt-4o-realtime-preview")
      refute OpenAI.chat_model?("gpt-4o-audio-preview")
      refute OpenAI.chat_model?("gpt-4o-transcribe")
      refute OpenAI.chat_model?("gpt-image-1")
      refute OpenAI.chat_model?("gpt-4o-search-preview")
      refute OpenAI.chat_model?("gpt-3.5-turbo-instruct")
    end

    test "filters out old completion-only and specialty families" do
      refute OpenAI.chat_model?("babbage-002")
      refute OpenAI.chat_model?("davinci-002")
      refute OpenAI.chat_model?("codex-mini-latest")
      refute OpenAI.chat_model?("computer-use-preview")
    end

    test "handles nil" do
      refute OpenAI.chat_model?(nil)
    end
  end

  describe "process_sse/2 — text deltas" do
    test "accumulates text chunks and calls on_chunk" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      acc = %{
        text: "",
        tool_calls: %{},
        finish_reason: nil,
        usage: %{input_tokens: 0, output_tokens: 0},
        on_chunk: fn msg -> Agent.update(agent, &[msg | &1]) end
      }

      data = """
      data: {"choices":[{"index":0,"delta":{"content":"Hello"}}]}
      data: {"choices":[{"index":0,"delta":{"content":" world"}}]}
      data: {"choices":[{"index":0,"finish_reason":"stop","delta":{}}]}
      data: [DONE]
      """

      acc = OpenAI.process_sse(data, acc)

      assert acc.text == "Hello world"
      assert acc.finish_reason == "stop"
      assert Enum.reverse(Agent.get(agent, & &1)) == [{:text, "Hello"}, {:text, " world"}]
    end

    test "captures usage from final chunk" do
      acc = fresh_acc()
      data = ~s(data: {"choices":[],"usage":{"prompt_tokens":42,"completion_tokens":7}}\n)

      acc = OpenAI.process_sse(data, acc)

      assert acc.usage == %{input_tokens: 42, output_tokens: 7}
    end

    test "accumulates tool-call arguments across deltas and finalizes JSON" do
      acc = %{
        text: "",
        tool_calls: %{},
        finish_reason: nil,
        usage: %{input_tokens: 0, output_tokens: 0},
        on_chunk: fn _ -> :ok end
      }

      data = """
      data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"search"}}]}}]}
      data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"q\\":"}}]}}]}
      data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"cats\\"}"}}]}}]}
      data: {"choices":[{"finish_reason":"tool_calls","delta":{}}]}
      """

      acc = OpenAI.process_sse(data, acc)
      content = OpenAI.finalize_content(acc)

      assert [
               %{
                 "type" => "tool_use",
                 "id" => "call_1",
                 "name" => "search",
                 "input" => %{"q" => "cats"}
               }
             ] =
               content
    end

    test "ignores malformed JSON lines" do
      acc = fresh_acc()

      data = """
      data: not json
      data: {"choices":[{"delta":{"content":"ok"}}]}
      """

      acc = OpenAI.process_sse(data, acc)
      assert acc.text == "ok"
    end

    test "recovers content when a JSON event spans two chunks" do
      # Regression for the SSE boundary bug that caused Heckler's output
      # to lose characters like "/" and " [[" at word boundaries — TCP
      # packets don't align with SSE event boundaries, so the parser
      # must buffer incomplete lines across callbacks.
      acc = fresh_acc()

      # Split the single event `..."content":"Hello world"...` across
      # two chunks, ending chunk1 mid-string with no closing quote.
      chunk1 = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello "
      chunk2 = "world\"}}]}\ndata: {\"choices\":[{\"delta\":{\"content\":\"!\"}}]}\n"

      acc = OpenAI.process_sse(chunk1, acc)
      # Partial event: should be buffered, no content leaked yet.
      assert acc.text == ""
      assert acc.buffer != ""

      acc = OpenAI.process_sse(chunk2, acc)
      assert acc.text == "Hello world!"
    end

    test "handles a single event split char-by-char" do
      # Pathological case: one byte at a time.
      acc = fresh_acc()
      data = ~s(data: {"choices":[{"delta":{"content":"abc"}}]}\n)

      acc =
        data
        |> String.graphemes()
        |> Enum.reduce(acc, fn ch, acc -> OpenAI.process_sse(ch, acc) end)

      assert acc.text == "abc"
    end
  end

  defp fresh_acc do
    %{
      text: "",
      tool_calls: %{},
      finish_reason: nil,
      usage: %{input_tokens: 0, output_tokens: 0},
      on_chunk: fn _ -> :ok end,
      buffer: ""
    }
  end

  describe "finalize_content/1" do
    test "produces Anthropic-shaped content blocks (text then tool_use)" do
      acc = %{
        text: "Here goes:",
        tool_calls: %{
          0 => %{"id" => "call_1", "name" => "search", "args" => ~s({"q":"x"})}
        },
        finish_reason: "tool_calls",
        usage: %{input_tokens: 0, output_tokens: 0},
        on_chunk: fn _ -> :ok end
      }

      assert OpenAI.finalize_content(acc) == [
               %{"type" => "text", "text" => "Here goes:"},
               %{
                 "type" => "tool_use",
                 "id" => "call_1",
                 "name" => "search",
                 "input" => %{"q" => "x"}
               }
             ]
    end
  end
end
