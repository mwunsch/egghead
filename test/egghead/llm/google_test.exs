defmodule Egghead.LLM.GoogleTest do
  use ExUnit.Case, async: true

  alias Egghead.LLM.Google

  describe "gemini_chat_model?/1" do
    test "keeps gemini chat models" do
      assert Google.gemini_chat_model?(%{"name" => "models/gemini-2.0-flash"})
      assert Google.gemini_chat_model?(%{"name" => "models/gemini-2.5-flash"})
      assert Google.gemini_chat_model?(%{"name" => "models/gemini-1.5-pro"})
    end

    test "filters out embeddings, imagen, tts, aqa, native-audio" do
      refute Google.gemini_chat_model?(%{"name" => "models/text-embedding-004"})
      refute Google.gemini_chat_model?(%{"name" => "models/embedding-001"})
      refute Google.gemini_chat_model?(%{"name" => "models/gemini-embedding-001"})
      refute Google.gemini_chat_model?(%{"name" => "models/aqa"})
      refute Google.gemini_chat_model?(%{"name" => "models/imagen-3.0-generate-001"})
      refute Google.gemini_chat_model?(%{"name" => "models/gemini-2.5-flash-image-generation"})
      refute Google.gemini_chat_model?(%{"name" => "models/gemini-2.5-flash-preview-tts"})

      refute Google.gemini_chat_model?(%{
               "name" => "models/gemini-2.5-flash-native-audio-dialog"
             })
    end

    test "rejects non-gemini and malformed entries" do
      refute Google.gemini_chat_model?(%{"name" => "models/palm-2"})
      refute Google.gemini_chat_model?(%{})
      refute Google.gemini_chat_model?(nil)
    end
  end

  describe "build_body/2" do
    test "builds Gemini-shaped body with maxOutputTokens and system instruction" do
      body =
        Google.build_body([%{role: "user", content: "hi"}],
          model: "gemini-2.5-flash",
          max_tokens: 2048,
          system: "You are Heckler."
        )

      assert body.generationConfig.maxOutputTokens == 2048
      assert %{parts: [%{text: "You are Heckler."}]} = body.systemInstruction
      assert [%{role: "user", parts: [%{"text" => "hi"}]}] = body.contents
    end

    test "passes temperature through when provided" do
      body = Google.build_body([%{role: "user", content: "hi"}], temperature: 0.4)
      assert body.generationConfig.temperature == 0.4
    end

    test "omits temperature when not provided" do
      body = Google.build_body([%{role: "user", content: "hi"}], [])
      refute Map.has_key?(body.generationConfig, :temperature)
    end
  end

  describe "process_sse/2 — text deltas" do
    test "accumulates text parts and fires on_chunk" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      acc = %{
        text: "",
        tool_calls: [],
        finish_reason: nil,
        usage: %{input_tokens: 0, output_tokens: 0},
        on_chunk: fn msg -> Agent.update(agent, &[msg | &1]) end
      }

      data = """
      data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"}}]}
      data: {"candidates":[{"content":{"parts":[{"text":" there"}],"role":"model"}}]}
      data: {"candidates":[{"content":{"parts":[{"text":"!"}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":3}}
      """

      acc = Google.process_sse(data, acc)
      content = Google.finalize_stream_content(acc)

      assert acc.text == "Hello there!"
      assert acc.finish_reason == "end_turn"
      assert acc.usage == %{input_tokens: 5, output_tokens: 3}
      assert [%{"type" => "text", "text" => "Hello there!"}] = content

      assert Enum.reverse(Agent.get(agent, & &1)) == [
               {:text, "Hello"},
               {:text, " there"},
               {:text, "!"}
             ]
    end

    test "captures function calls arriving whole in a part" do
      acc = %{
        text: "",
        tool_calls: [],
        finish_reason: nil,
        usage: %{input_tokens: 0, output_tokens: 0},
        on_chunk: fn _ -> :ok end
      }

      data =
        ~s(data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"search","args":{"q":"cats"}}}],"role":"model"},"finishReason":"TOOL_USE"}]}\n)

      acc = Google.process_sse(data, acc)
      content = Google.finalize_stream_content(acc)

      assert acc.finish_reason == "tool_use"
      assert [%{"type" => "tool_use", "name" => "search", "input" => %{"q" => "cats"}}] = content
    end

    test "ignores malformed JSON lines" do
      acc = fresh_acc()

      data = """
      data: not json
      data: {"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}
      """

      acc = Google.process_sse(data, acc)
      assert acc.text == "ok"
    end

    test "recovers content when a JSON event spans two chunks" do
      # Regression for SSE boundary data loss — TCP packets aren't
      # aligned to SSE events, so the parser must buffer partial lines.
      acc = fresh_acc()

      chunk1 = ~s(data: {"candidates":[{"content":{"parts":[{"text":"Hello )
      chunk2 = ~s(world"}]}}]}\n)

      acc = Google.process_sse(chunk1, acc)
      assert acc.text == ""
      acc = Google.process_sse(chunk2, acc)
      assert acc.text == "Hello world"
    end
  end

  defp fresh_acc do
    %{
      text: "",
      tool_calls: [],
      finish_reason: nil,
      usage: %{input_tokens: 0, output_tokens: 0},
      on_chunk: fn _ -> :ok end,
      buffer: ""
    }
  end
end
