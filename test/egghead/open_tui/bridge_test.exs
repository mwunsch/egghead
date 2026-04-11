defmodule Egghead.OpenTUI.BridgeTest do
  use ExUnit.Case, async: false

  alias Egghead.OpenTUI.Bridge

  @moduledoc """
  Smoke test for the NIF bridge. Deliberately does NOT call
  `setup_terminal/1` or any draw primitives — those write escape
  sequences to stdout and would corrupt test output. We verify
  only that:

    1. The NIF loads
    2. A renderer handle can be allocated
    3. The handle can be destroyed
    4. A bogus handle returns badarg

  The visual end-to-end check is `mix egghead.tui` (or
  `mix tui.records`), run by hand.
  """

  test "create_renderer returns an integer handle" do
    assert {:ok, handle} = Bridge.create_renderer(80, 24)
    assert is_integer(handle)
    assert handle > 0
    assert :ok = Bridge.destroy_renderer(handle)
  end

  test "destroy_renderer with bogus handle returns badarg" do
    assert_raise ArgumentError, fn ->
      Bridge.destroy_renderer(999_999_999)
    end
  end

  test "multiple renderers get distinct handles" do
    assert {:ok, h1} = Bridge.create_renderer(80, 24)
    assert {:ok, h2} = Bridge.create_renderer(40, 12)
    assert h1 != h2
    assert :ok = Bridge.destroy_renderer(h1)
    assert :ok = Bridge.destroy_renderer(h2)
  end
end
