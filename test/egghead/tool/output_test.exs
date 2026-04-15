defmodule Egghead.Tool.OutputTest do
  use ExUnit.Case, async: true

  alias Egghead.Tool.Output

  describe "apply/2" do
    test "small UTF-8 output passes through unchanged" do
      assert {:ok, "hello world"} = Output.apply("hello world")
    end

    test "non-UTF-8 binary is refused" do
      binary = <<0xFF, 0xFE, 0xFD, 0xFC>>
      assert {:binary, notice} = Output.apply(binary)
      assert notice =~ "non-text"
    end

    test "oversized output is truncated with head+tail preservation" do
      text = String.duplicate("abcde\n", 30_000)
      assert {:truncated, result, meta} = Output.apply(text, max_bytes: 1000)
      assert byte_size(result) <= 1200
      assert result =~ "elided"
      assert meta.original_bytes > 1000
      assert meta.elided_bytes > 0
    end

    test "truncation keeps the tail (where errors usually are)" do
      head_marker = String.duplicate("HEAD\n", 50)
      tail_marker = "final-error-at-end"
      text = head_marker <> String.duplicate("filler\n", 1000) <> tail_marker

      {:truncated, result, _} = Output.apply(text, max_bytes: 500)
      assert result =~ tail_marker
    end
  end

  describe "append/3" do
    test "appends below cap" do
      assert {"hello", :ok} = Output.append("", "hello")
      assert {"helloworld", :ok} = Output.append("hello", "world", max_bytes: 100)
    end

    test "caps at limit" do
      assert {"1234567890", :capped} =
               Output.append("12345", "67890abcde", max_bytes: 10)
    end

    test "returns :capped when already full" do
      assert {"1234567890", :capped} =
               Output.append("1234567890", "more", max_bytes: 10)
    end
  end
end
