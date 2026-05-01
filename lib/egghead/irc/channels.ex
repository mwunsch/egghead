defmodule Egghead.IRC.Channels do
  @moduledoc """
  Per-connection channel-name aliasing.

  Strict IRC clients (ERC, irssi) only open a buffer when the JOIN
  echo's channel name matches the channel name they typed — so if the
  user types `JOIN #default` we have to echo `JOIN #default`, not the
  canonical `JOIN #chat-2026-04-30-3906`. This module owns:

  - `resolve_alias/1` — incoming JOIN target → `{canonical, alias}`
  - `display_channel/2` — `{room_id, alias_map}` → wire-side channel name
    used for every outbound JOIN/PART/PRIVMSG/NAMES/action for that room
  - `target_to_room_id/2` — inbound channel name → canonical room id,
    walking three layers (per-conn alias, global `#default`, NickMap)

  Pure functions over a `%{room_id => alias_string}` map.
  """

  alias Egghead.IRC.NickMap

  @type alias_map :: %{optional(String.t()) => String.t()}

  @doc """
  Resolve a channel name from an inbound JOIN. Returns
  `{canonical_channel, alias_or_nil}` — `#default` resolves to the
  configured default room's canonical channel and an alias of
  `#default`; everything else is its own canonical with no alias.
  """
  @spec resolve_alias(String.t()) :: {String.t(), String.t() | nil}
  def resolve_alias("#default") do
    case Egghead.default_room() do
      nil -> {"#default", nil}
      room_id -> {NickMap.room_to_channel(room_id), "#default"}
    end
  end

  def resolve_alias(other), do: {other, nil}

  @doc "Record the alias name (if any) the user typed for `room_id`."
  @spec put_alias(alias_map, String.t(), String.t() | nil) :: alias_map
  def put_alias(aliases, _room_id, nil), do: aliases
  def put_alias(aliases, room_id, alias_name), do: Map.put(aliases, room_id, alias_name)

  @doc """
  Channel name to use when emitting anything for `room_id` back over
  the wire on this connection. Falls through to the canonical name
  when no alias is set.
  """
  @spec display_channel(alias_map, String.t()) :: String.t()
  def display_channel(aliases, room_id) do
    Map.get(aliases, room_id) || NickMap.room_to_channel(room_id)
  end

  @doc """
  Reverse lookup for inbound traffic — channel name → canonical room
  id. Three layers:

  1. Per-connection alias (set on JOIN #default → that room id)
  2. Global `#default` alias (so KICK/INVITE work even without a JOIN)
  3. Canonical via NickMap

  Returns the room id, or nil if the channel name doesn't resolve.
  """
  @spec target_to_room_id(alias_map, String.t()) :: String.t() | nil
  def target_to_room_id(aliases, channel) do
    cond do
      match = Enum.find(aliases, fn {_room_id, alias_name} -> alias_name == channel end) ->
        elem(match, 0)

      channel == "#default" ->
        Egghead.default_room() || NickMap.channel_to_room(channel)

      true ->
        NickMap.channel_to_room(channel)
    end
  end
end
