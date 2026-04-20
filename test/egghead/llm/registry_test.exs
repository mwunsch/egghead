defmodule Egghead.LLM.RegistryTest do
  use ExUnit.Case, async: true

  alias Egghead.LLM.Registry

  describe "preset/1" do
    test "returns base_url for known OpenAI-compatible presets" do
      assert %{base_url: "https://api.x.ai/v1"} = Registry.preset("xai")
      assert %{base_url: "https://api.groq.com/openai/v1"} = Registry.preset("groq")
      assert %{base_url: "https://api.deepseek.com"} = Registry.preset("deepseek")
      assert %{base_url: "https://api.mistral.ai/v1"} = Registry.preset("mistral")
      assert %{base_url: "https://openrouter.ai/api/v1"} = Registry.preset("openrouter")
    end

    test "marks local runners as optional_key" do
      assert %{optional_key: true} = Registry.preset("ollama")
      assert %{optional_key: true} = Registry.preset("lmstudio")
    end

    test "native providers have no preset entry (they don't need a base_url)" do
      assert Registry.preset("anthropic") == nil
      assert Registry.preset("openai") == nil
      assert Registry.preset("google") == nil
    end

    test "unknown provider returns nil" do
      assert Registry.preset("made-up") == nil
    end
  end

  describe "env_vars/1" do
    test "canonical env vars per provider" do
      assert Registry.env_vars("anthropic") == ["ANTHROPIC_API_KEY"]
      assert Registry.env_vars("openai") == ["OPENAI_API_KEY"]
      assert Registry.env_vars("google") == ["GOOGLE_API_KEY", "GEMINI_API_KEY"]
      assert Registry.env_vars("xai") == ["XAI_API_KEY"]
      assert Registry.env_vars("groq") == ["GROQ_API_KEY"]
      assert Registry.env_vars("deepseek") == ["DEEPSEEK_API_KEY"]
      assert Registry.env_vars("mistral") == ["MISTRAL_API_KEY"]
      assert Registry.env_vars("openrouter") == ["OPENROUTER_API_KEY"]
    end

    test "unknown provider returns empty list" do
      assert Registry.env_vars("made-up") == []
    end
  end

  describe "preset_names/0" do
    test "lists the curated OpenAI-compat presets" do
      names = Registry.preset_names()
      assert "xai" in names
      assert "groq" in names
      assert "deepseek" in names
      assert "mistral" in names
      assert "openrouter" in names
      assert "ollama" in names
      assert "lmstudio" in names
    end
  end

  describe "determine_module/2 — all presets route through OpenAI adapter" do
    test "OpenAI-compat presets" do
      for name <- ~w(xai groq deepseek mistral openrouter ollama lmstudio) do
        assert Registry.determine_module(name) == Egghead.LLM.OpenAI,
               "#{name} should route through OpenAI adapter"
      end
    end

    test "native providers use their own module" do
      assert Registry.determine_module("anthropic") == Egghead.LLM.Anthropic
      assert Registry.determine_module("openai") == Egghead.LLM.OpenAI
      assert Registry.determine_module("google") == Egghead.LLM.Google
    end

    test "openai_compatible api type routes to OpenAI" do
      assert Registry.determine_module("anything", "openai_compatible") == Egghead.LLM.OpenAI
    end
  end
end
