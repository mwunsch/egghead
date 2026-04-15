defmodule Egghead.MCP.Client.Registry do
  @moduledoc """
  Name-to-pid lookup for `Egghead.MCP.Client.Server` processes.

  Each configured MCP server registers under its configured name
  (e.g. `"exa"`) so callers can address it without knowing its pid.
  Thin wrapper over `Registry` — exposed as a module so the startup
  wiring reads cleanly.
  """

  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end
end
