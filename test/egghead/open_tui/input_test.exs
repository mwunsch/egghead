defmodule Egghead.OpenTUI.InputTest do
  use ExUnit.Case, async: true

  alias Egghead.OpenTUI.Input

  # Build a stateful reader function that hands out the supplied
  # bytes one at a time. After the bytes run out, every call
  # returns `:timeout` — which the parser treats as bare ESC for
  # the disambiguation peek and as :eof at the top level.
  defp reader(bytes) do
    {:ok, agent} = Agent.start_link(fn -> bytes end)

    fn _timeout ->
      Agent.get_and_update(agent, fn
        [] -> {:timeout, []}
        [b | rest] -> {{:ok, b}, rest}
      end)
    end
  end

  describe "printable + control bytes" do
    test "decodes a printable ASCII byte" do
      assert {:char, "x"} == Input.parse(reader([?x]))
    end

    test "decodes Ctrl+A" do
      assert {:key, :ctrl_a} == Input.parse(reader([0x01]))
    end

    test "decodes DEL as backspace" do
      assert {:key, :backspace} == Input.parse(reader([0x7F]))
    end

    test "CR and LF both surface as :enter" do
      assert {:key, :enter} == Input.parse(reader([0x0D]))
      assert {:key, :enter} == Input.parse(reader([0x0A]))
    end

    test "Tab is :tab" do
      assert {:key, :tab} == Input.parse(reader([0x09]))
    end
  end

  describe "bare ESC vs escape sequences" do
    test "lone ESC followed by no byte → :escape" do
      assert {:key, :escape} == Input.parse(reader([0x1B]))
    end

    test "ESC + b → :alt_b" do
      assert {:key, :alt_b} == Input.parse(reader([0x1B, ?b]))
    end

    test "ESC + DEL → :alt_backspace" do
      assert {:key, :alt_backspace} == Input.parse(reader([0x1B, 0x7F]))
    end

    test "ESC + CR → :alt_enter (universal Alt+Enter fallback)" do
      assert {:key, :alt_enter} == Input.parse(reader([0x1B, 0x0D]))
    end

    test "ESC + LF → :alt_enter" do
      assert {:key, :alt_enter} == Input.parse(reader([0x1B, 0x0A]))
    end
  end

  describe "CSI arrow keys + page nav" do
    test "ESC [ A → :up" do
      assert {:key, :up} == Input.parse(reader([0x1B, ?[, ?A]))
    end

    test "ESC [ B → :down" do
      assert {:key, :down} == Input.parse(reader([0x1B, ?[, ?B]))
    end

    test "ESC [ Z → :shift_tab" do
      assert {:key, :shift_tab} == Input.parse(reader([0x1B, ?[, ?Z]))
    end

    test "ESC [ 5 ~ → :page_up" do
      assert {:key, :page_up} == Input.parse(reader([0x1B, ?[, ?5, ?~]))
    end

    test "ESC [ 6 ~ → :page_down" do
      assert {:key, :page_down} == Input.parse(reader([0x1B, ?[, ?6, ?~]))
    end
  end

  describe "F-keys" do
    test "ESC O P → :f1 (SS3 form)" do
      assert {:key, :f1} == Input.parse(reader([0x1B, ?O, ?P]))
    end

    test "ESC O Q → :f2 (SS3 form)" do
      assert {:key, :f2} == Input.parse(reader([0x1B, ?O, ?Q]))
    end

    test "ESC [ 11 ~ → :f1 (CSI tilde form)" do
      assert {:key, :f1} == Input.parse(reader([0x1B, ?[, ?1, ?1, ?~]))
    end

    test "ESC [ 12 ~ → :f2 (CSI tilde form)" do
      assert {:key, :f2} == Input.parse(reader([0x1B, ?[, ?1, ?2, ?~]))
    end
  end

  describe "Kitty CSI u" do
    test "ESC [ 13 u → :enter (bare Enter via Kitty protocol)" do
      assert {:key, :enter} == Input.parse(reader([0x1B, ?[, ?1, ?3, ?u]))
    end

    test "ESC [ 13 ; 2 u → :shift_enter" do
      assert {:key, :shift_enter} ==
               Input.parse(reader([0x1B, ?[, ?1, ?3, ?;, ?2, ?u]))
    end

    test "ESC [ 13 ; 3 u → :alt_enter" do
      assert {:key, :alt_enter} ==
               Input.parse(reader([0x1B, ?[, ?1, ?3, ?;, ?3, ?u]))
    end

    test "ESC [ 13 ; 5 u → :ctrl_enter" do
      assert {:key, :ctrl_enter} ==
               Input.parse(reader([0x1B, ?[, ?1, ?3, ?;, ?5, ?u]))
    end

    test "Kitty modifiers carrying a sub-event field decode the leading mods only" do
      # `13;2:1u` → shift, with sub-event 1 (press). We treat it
      # as :shift_enter and ignore the sub-event.
      bytes = [0x1B, ?[, ?1, ?3, ?;, ?2, ?:, ?1, ?u]
      assert {:key, :shift_enter} == Input.parse(reader(bytes))
    end

    test "ESC [ 9 ; 2 u → :shift_tab via Kitty" do
      assert {:key, :shift_tab} ==
               Input.parse(reader([0x1B, ?[, ?9, ?;, ?2, ?u]))
    end
  end

  describe "bracketed paste" do
    test "captures the payload between 200~ and 201~" do
      payload = "hello world"
      bytes = paste_bytes(payload)
      assert {:paste, "hello world"} == Input.parse(reader(bytes))
    end

    test "preserves embedded newlines" do
      payload = "line one\nline two\nline three"
      assert {:paste, ^payload} = Input.parse(reader(paste_bytes(payload)))
    end

    test "strips control characters except \\n and \\t" do
      # Embed a literal BEL (0x07) in the payload — the parser
      # should drop it but keep the surrounding text.
      bytes = paste_bytes_raw([?a, 0x07, ?b])
      assert {:paste, "ab"} == Input.parse(reader(bytes))
    end

    test "an unterminated paste returns whatever was buffered" do
      bytes = [0x1B, ?[, ?2, ?0, ?0, ?~ | ~c"abc"]
      assert {:paste, "abc"} == Input.parse(reader(bytes))
    end

    defp paste_bytes(text) do
      paste_bytes_raw(:binary.bin_to_list(text))
    end

    defp paste_bytes_raw(body) do
      open = [0x1B, ?[, ?2, ?0, ?0, ?~]
      close = [0x1B, ?[, ?2, ?0, ?1, ?~]
      open ++ body ++ close
    end
  end

  describe "garbage / unknown sequences" do
    test "unknown CSI final byte → :unknown" do
      # ESC [ X — `X` is not a recognized final byte
      assert {:key, :unknown} == Input.parse(reader([0x1B, ?[, ?X]))
    end
  end
end
