defmodule Egghead.IRC.Agents do
  @moduledoc """
  Shared agent-roster lookups for the IRC layer.

  `Egghead.Agent.list_agents/0` requires the record store to be up. In
  tests (and degraded headless modes) it isn't, and would crash the
  caller — wrap so resolution / WHOIS gracefully report "no such nick"
  instead of dropping the socket.
  """

  alias Egghead.IRC.NickMap
  alias Egghead.Chat.Room

  @doc "Live agent roster, or `[]` if the agent layer is down."
  def list do
    try do
      Egghead.Agent.list_agents()
    catch
      _, _ -> []
    end
  end

  @doc "Find an agent record whose IRC nick matches `nick`, or nil."
  def find_by_nick(nick) do
    Enum.find(list(), fn a -> NickMap.id_to_nick(a.id) == nick end)
  end

  @doc """
  Find an agent currently joined to `room_id` by IRC nick.

  Returns `{:ok, agent_id}` or `:not_found`. Used by KICK / MUTE /
  UNMUTE — only the in-room roster, not the whole agent registry.
  """
  def find_in_room(nick, room_id) do
    if Room.exists?(room_id) do
      case Room.get_state(room_id) do
        %{agents: agents} ->
          case Enum.find(agents, fn id -> NickMap.id_to_nick(id) == nick end) do
            nil -> :not_found
            id -> {:ok, id}
          end

        _ ->
          :not_found
      end
    else
      :not_found
    end
  end

  @doc "Channel names for every running room that has `agent_id` joined."
  def channels(agent_id) do
    Room.list_ids()
    |> Enum.filter(fn room_id ->
      Room.exists?(room_id) and
        case Room.get_state(room_id) do
          %{agents: agents} -> agent_id in agents
          _ -> false
        end
    end)
    |> Enum.map(&NickMap.room_to_channel/1)
  end
end
