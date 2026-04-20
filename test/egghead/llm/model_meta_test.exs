defmodule Egghead.LLM.ModelMetaTest do
  use ExUnit.Case, async: true

  alias Egghead.LLM.ModelMeta

  describe "context_window/1 — OpenAI" do
    test "GPT-5 family → 400K" do
      for id <- ~w(gpt-5 gpt-5-mini gpt-5-nano gpt-5.1 gpt-5.2 gpt-5.4) do
        assert ModelMeta.context_window(id) == 400_000, "wrong ctx for #{id}"
        assert ModelMeta.max_output(id) == 128_000, "wrong max out for #{id}"
      end
    end

    test "GPT-4.1 family → 1M" do
      assert ModelMeta.context_window("gpt-4.1") == 1_047_576
      assert ModelMeta.context_window("gpt-4.1-mini") == 1_047_576
      assert ModelMeta.max_output("gpt-4.1") == 32_768
    end

    test "GPT-4o / GPT-4-turbo / chatgpt-4o → 128K" do
      assert ModelMeta.context_window("gpt-4o") == 128_000
      assert ModelMeta.context_window("gpt-4o-mini") == 128_000
      assert ModelMeta.context_window("chatgpt-4o-latest") == 128_000
      assert ModelMeta.context_window("gpt-4-turbo") == 128_000
    end

    test "older GPT-4 / GPT-3.5 preserved" do
      assert ModelMeta.context_window("gpt-4") == 8_192
      assert ModelMeta.context_window("gpt-3.5-turbo") == 16_385
    end

    test "o-series reasoning models" do
      assert ModelMeta.context_window("o1") == 200_000
      assert ModelMeta.context_window("o1-mini") == 128_000
      assert ModelMeta.context_window("o1-preview") == 128_000
      assert ModelMeta.context_window("o3-mini") == 200_000
      assert ModelMeta.context_window("o4-mini") == 200_000
      assert ModelMeta.max_output("o1-mini") == 65_536
      assert ModelMeta.max_output("o3-mini") == 100_000
    end
  end

  describe "context_window/1 — Anthropic" do
    test "claude 4/4.5/4.6 family → 200K" do
      assert ModelMeta.context_window("claude-sonnet-4-6") == 200_000
      assert ModelMeta.context_window("claude-opus-4-7") == 200_000
      assert ModelMeta.context_window("claude-haiku-4-5") == 200_000
      assert ModelMeta.context_window("claude-3-5-sonnet-20241022") == 200_000
    end

    test "max_output per family" do
      assert ModelMeta.max_output("claude-opus-4-7") == 32_000
      assert ModelMeta.max_output("claude-sonnet-4-6") == 64_000
      assert ModelMeta.max_output("claude-haiku-4-5") == 8_192
    end
  end

  describe "context_window/1 — Google Gemini" do
    test "Gemini 1.5 Pro → 2M, others → 1M" do
      assert ModelMeta.context_window("gemini-1.5-pro") == 2_097_152
      assert ModelMeta.context_window("gemini-1.5-flash") == 1_048_576
      assert ModelMeta.context_window("gemini-2.0-flash") == 1_048_576
      assert ModelMeta.context_window("gemini-2.5-flash") == 1_048_576
      assert ModelMeta.context_window("gemini-2.5-pro") == 1_048_576
    end
  end

  describe "context_window/1 — xAI Grok" do
    test "Grok-4 → 256K, Grok-3/2 → 131K" do
      assert ModelMeta.context_window("grok-4") == 256_000
      assert ModelMeta.context_window("grok-4-1-fast-reasoning") == 256_000
      assert ModelMeta.context_window("grok-3") == 131_072
      assert ModelMeta.context_window("grok-3-mini") == 131_072
      assert ModelMeta.context_window("grok-2-1212") == 131_072
    end

    test "max_output → 16K" do
      assert ModelMeta.max_output("grok-4") == 16_384
    end
  end

  describe "context_window/1 — DeepSeek" do
    test "V4 → 1M, V3/R1 → 128K" do
      assert ModelMeta.context_window("deepseek-v4") == 1_000_000
      assert ModelMeta.context_window("deepseek-v3") == 128_000
      assert ModelMeta.context_window("deepseek-r1") == 128_000
      assert ModelMeta.context_window("deepseek-chat") == 128_000
    end
  end

  describe "context_window/1 — Mistral" do
    test "Large/Medium/Small → 128K, plain mistral → 32K" do
      assert ModelMeta.context_window("mistral-large-2411") == 128_000
      assert ModelMeta.context_window("mistral-medium-2506") == 128_000
      assert ModelMeta.context_window("mistral-small-2506") == 128_000
      assert ModelMeta.context_window("mistral-nemo-2407") == 128_000
      assert ModelMeta.context_window("ministral-8b") == 128_000
      assert ModelMeta.context_window("pixtral-12b") == 128_000
      assert ModelMeta.context_window("codestral-2501") == 32_768
    end
  end

  describe "context_window/1 — Meta Llama" do
    test "3.1+ → 128K, 3.0 → 8K" do
      assert ModelMeta.context_window("llama-3.3-70b") == 128_000
      assert ModelMeta.context_window("llama-3.1-70b") == 128_000
      assert ModelMeta.context_window("llama-3.2-11b") == 128_000
      assert ModelMeta.context_window("llama-3-8b") == 8_192
    end
  end

  describe "lookup/1" do
    test "returns a tuple of {ctx, max_out}" do
      assert ModelMeta.lookup("gpt-5.4") == {400_000, 128_000}
      assert ModelMeta.lookup("grok-4") == {256_000, 16_384}
      assert ModelMeta.lookup("completely-unknown-model") == {nil, nil}
    end

    test "handles nil" do
      assert ModelMeta.lookup(nil) == {nil, nil}
    end
  end

  describe "unknown models" do
    test "returns nil for families we don't know" do
      assert ModelMeta.context_window("qwen-2.5-72b") == nil
      assert ModelMeta.context_window("phi-4") == nil
      assert ModelMeta.max_output("some-custom-model") == nil
    end
  end
end
