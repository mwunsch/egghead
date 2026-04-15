defmodule Egghead.MCP.Client.Supervisor do
  @moduledoc """
  DynamicSupervisor for `Egghead.MCP.Client.Server` children.

  One child per configured MCP server. Restart intensity is tuned for
  flappy external processes — an unreachable server shouldn't take the
  supervisor down, but a runaway crash loop should eventually give up
  and leave the server offline until restart.
  """

  use DynamicSupervisor

  alias Egghead.MCP.Client.Server

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    )
  end

  @doc "Start a client server under this supervisor."
  def start_server(config) do
    DynamicSupervisor.start_child(__MODULE__, {Server, config})
  end

  @doc "List configured server names (based on registered processes)."
  def list_running do
    Registry.select(Egghead.MCP.Client.Registry, [
      {{:"$1", :_, :_}, [], [:"$1"]}
    ])
  end
end
