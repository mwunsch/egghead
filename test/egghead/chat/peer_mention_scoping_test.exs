defmodule Egghead.Chat.PeerMentionScopingTest do
  @moduledoc """
  Regression: peer-agent @-mentions must respect the room's roster.
  When agent A mentions @b in a response, the Coordinator should only
  activate B if B is *joined* to that room. Otherwise a kicked agent
  silently re-activates whenever any other agent name-drops it, which
  defeats `/kick` and `idle: true`.

  Reproduced by: kick `index`, ask "Who's here now?", another agent
  responds with "@index, @others, …", Index speaks again from the
  dead.
  """

  use ExUnit.Case

  alias Egghead.Chat.Coordinator
  alias Egghead.Chat.Coordinator.AgentInfo
  alias Egghead.Chat.Room

  setup_all do
    case Phoenix.PubSub.Supervisor.start_link(name: Egghead.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  describe "Coordinator handle_info :agent_mentions" do
    test "ignores mentions of agents not joined to the room" do
      tag = :erlang.unique_integer([:positive])
      coord_name = :"coord_peer_mention_#{tag}"
      {:ok, coord} = Coordinator.start_link(name: coord_name)
      on_exit(fn -> if Process.alive?(coord), do: GenServer.stop(coord) end)

      # Two agents in the global registry — only "in-room" is joined to
      # the room. "kicked" exists in the registry but was never joined
      # (stand-in for "the user kicked them").
      Coordinator.register_agent(coord, "in-room", %{
        name: "InRoom",
        capabilities: [],
        tags: [],
        disposition: ""
      })

      Coordinator.register_agent(coord, "kicked", %{
        name: "Kicked",
        capabilities: [],
        tags: [],
        disposition: ""
      })

      room_id = "peer-mention-#{tag}"
      {:ok, _} = Room.start_link(id: room_id)
      on_exit(fn -> if Room.exists?(room_id), do: Room.stop(room_id) end)
      Room.join(room_id, "in-room")

      Coordinator.watch_room(coord, room_id)

      candidates =
        Coordinator.scope_to_room(:sys.get_state(coord).agents, room_id)

      assert Map.has_key?(candidates, "in-room")

      refute Map.has_key?(candidates, "kicked"),
             "scope_to_room should drop a not-joined agent — that's the " <>
               "input the :agent_mentions handler now reads from"

      # Resolve a peer's mention list against the SCOPED candidate pool.
      # An agent who isn't joined to the room must not be summoned even
      # though they exist in the global registry.
      resolved_when_in_room =
        find_agent_ids(candidates, ["in-room"])

      resolved_when_kicked =
        find_agent_ids(candidates, ["kicked"])

      assert resolved_when_in_room == ["in-room"]

      assert resolved_when_kicked == [],
             "@kicked must not resolve through scope_to_room — peer " <>
               "mentions must respect /kick (and `idle: true`)"
    end
  end

  defp find_agent_ids(candidates, ids) do
    candidates
    |> Map.values()
    |> Enum.filter(fn %AgentInfo{id: id} -> id in ids end)
    |> Enum.map(& &1.id)
  end
end
