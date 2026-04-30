defmodule Egghead.Chat.QuietIdleTest do
  @moduledoc """
  Coverage for the agent properties `quiet: true` and `idle: true`.

  - `quiet?` is the property formerly hardcoded as `id == "index"` in
    the Coordinator's tier-1 filter and activation sort. It generalises:
    a quiet agent does not respond to open messages when non-quiet
    agents are present, but participates normally on broadcast modes
    (`@everyone`, `@jam`) and direct mentions.
  - `idle?` keeps an agent out of rooms by default. It only enters a
    room via explicit `/invite` or via `Egghead.create_room(agents:
    ids)`.
  """

  use ExUnit.Case

  alias Egghead.Chat.Coordinator
  alias Egghead.Chat.Coordinator.AgentInfo

  setup_all do
    case Phoenix.PubSub.Supervisor.start_link(name: Egghead.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  describe "Coordinator.register_agent/3" do
    test "stores quiet? and idle? from the metadata map" do
      coord_name = :"coord_quiet_#{:erlang.unique_integer([:positive])}"
      {:ok, coord} = Coordinator.start_link(name: coord_name)
      on_exit(fn -> if Process.alive?(coord), do: GenServer.stop(coord) end)

      Coordinator.register_agent(coord, "quiet/agent", %{
        name: "Quietude",
        capabilities: [],
        tags: [],
        disposition: "",
        quiet?: true,
        idle?: false
      })

      Coordinator.register_agent(coord, "idle/agent", %{
        name: "Bench",
        capabilities: [],
        tags: [],
        disposition: "",
        quiet?: true,
        idle?: true
      })

      Coordinator.register_agent(coord, "noisy/agent", %{
        name: "Talker",
        capabilities: [],
        tags: [],
        disposition: ""
      })

      # Force a synchronous round-trip so the casts above land before
      # we read state.
      _ = Coordinator.list_registered(coord)
      state = :sys.get_state(coord)

      assert %AgentInfo{quiet?: true, idle?: false} = state.agents["quiet/agent"]
      assert %AgentInfo{quiet?: true, idle?: true} = state.agents["idle/agent"]
      assert %AgentInfo{quiet?: false, idle?: false} = state.agents["noisy/agent"]
    end
  end
end
