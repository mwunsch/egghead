defmodule Egghead.IRC.Forwarder do
  @moduledoc """
  Per-room PubSub forwarder. One linked process per (connection, room).

  `Phoenix.PubSub` doesn't tell `handle_info` which topic delivered a
  message — so each joined channel gets its own forwarder that
  subscribes to the room's PubSub topic and re-sends every event back
  to the parent connection tagged with the originating `room_id`.
  Linked to the connection process: socket close kills the forwarder,
  and unsubscribe is implicit when it exits.
  """

  alias Egghead.Chat.Room

  @pubsub Egghead.PubSub

  @doc """
  Spawn-link a forwarder for `room_id` that delivers
  `{:room_event, room_id, msg}` tuples back to `parent`. Returns the
  forwarder pid.
  """
  @spec start_link(pid, String.t()) :: pid
  def start_link(parent, room_id) do
    spawn_link(fn -> init(parent, room_id) end)
  end

  @doc "Stop a running forwarder. Idempotent."
  @spec stop(pid) :: :ok
  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :normal)
    :ok
  end

  defp init(parent, room_id) do
    Phoenix.PubSub.subscribe(@pubsub, Room.topic(room_id))
    loop(parent, room_id)
  end

  defp loop(parent, room_id) do
    receive do
      msg ->
        send(parent, {:room_event, room_id, msg})
        loop(parent, room_id)
    end
  end
end
