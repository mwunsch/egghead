defmodule Egghead.Agent.ResolveForInviteTest do
  @moduledoc """
  Regression: `/invite judge` failed with "no agent record for judge"
  because the resolver only special-cased `"index"` for the synthetic
  fallback. Built-ins now live in `priv/agents/` and the resolver must
  consult `Egghead.Agent.Builtin.fetch/1` for any id the store doesn't
  carry.
  """

  use ExUnit.Case, async: true

  alias Egghead.Agent
  alias Egghead.Record

  describe "Egghead.Agent.resolve_for_invite/1" do
    test "resolves the built-in `judge` even with no store record" do
      assert {:ok, %Record{id: "judge", class: :agent}} =
               Agent.resolve_for_invite("judge")
    end

    test "resolves the built-in `index` even with no store record" do
      assert {:ok, %Record{id: "index", class: :agent}} =
               Agent.resolve_for_invite("index")
    end

    test "errors for an unknown id" do
      tag = :erlang.unique_integer([:positive])

      assert {:error, "no agent record for unknown-" <> _} =
               Agent.resolve_for_invite("unknown-#{tag}")
    end
  end
end
